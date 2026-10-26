// Video Ad Builder renderer (video-ad-builder.html) - draws one frame of a 1080x1920 Reels ad at time t
// onto a canvas, and exports the whole ad to MP4 (WebCodecs H.264 + mp4-muxer, frame by frame, so it is
// exact even on a slow phone). Kept apart from js/videoAdBuilder.js so the drawing has no page/UI code.
//
// Ad shape (saved as VideoAds."Config", sql/supabase_video_ads.sql):
//   { version: 1, accent: '#3fe0d0', brand: { name, logo }, scenes: [scene...] }
//   scene: { style, duration, headline, sub, bullets[], dims[L,W,H], options, layers, paint, media, mediaType, button, footer }
//   style: 'logo' (shop logo big in the centre; older ads say 'fish') | 'tank' / 'stand' / 'sump' (draws itself to dims in inches; a tank
//          also takes options - see TANK_OPTIONS; a stand takes layers 1-4 and paint 'black'|'white') | 'water' (text only)
//          | 'payments' (the payment methods in scene.methods drop in as cards - see PAY_METHODS)
//          | 'delivery' (our own truck drives up to a house and hands over the wrapped aquarium)
//          | 'reviews' (five stars, then up to 3 real customer quotes in scene.reviews = [{ text, name }]
//            rise up as bubbles)
//          | 'photo' (your photo/video, falls back to water until one is chosen) | 'cta' (logo + button end card)
window.VideoAdRenderer = (function () {
  const W = 1080, H = 1920, FPS = 30, FADE = 0.75; // FADE = length of the tide transition
  const FONT = 'Montserrat, system-ui, sans-serif';
  const clamp = (v, a = 0, b = 1) => Math.max(a, Math.min(b, v));
  const easeOut = (x) => 1 - Math.pow(1 - clamp(x), 3);
  const easeInOut = (x) => { x = clamp(x); return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
  const rand = (i) => { const s = Math.sin(i * 127.1 + 311.7) * 43758.5453; return s - Math.floor(s); };
  const isVideo = (src, type) => (type ? type === 'video' || String(type).startsWith('video') : /\.(mp4|webm|mov|m4v)(\?|$)/i.test(src));

  // Dark text on a light accent, white on a dark one.
  function textOn(hex) {
    const m = /^#?([0-9a-f]{6})$/i.exec(hex || '');
    if (!m) return '#04222b';
    const n = parseInt(m[1], 16), r = n >> 16, g = (n >> 8) & 255, b = n & 255;
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.55 ? '#04222b' : '#ffffff';
  }
  function withAlpha(hex, a) {
    const m = /^#?([0-9a-f]{6})$/i.exec(hex || '');
    if (!m) return `rgba(63,224,208,${a})`;
    const n = parseInt(m[1], 16);
    return `rgba(${n >> 16},${(n >> 8) & 255},${n & 255},${a})`;
  }

  // Payment methods a 'payments' scene can show (scene.methods = keys; none set = all of them).
  const PAY_METHODS = [
    ['visa', 'Visa'], ['mastercard', 'Mastercard'], ['gcash', 'GCash'], ['maya', 'Maya'],
    ['qrph', 'QR Ph'], ['bank', 'Bank transfer'], ['cash', 'Cash']
  ];

  // Tank options (scene.options): these flags plus holes / dividers (counts) and extras (other
  // accessories, comma separated). Each one shows on the tank drawing and as a tag under it.
  const TANK_OPTIONS = [
    ['aio', 'AIO filter'], ['rimless', 'Rimless'], ['highStrip', 'High strip'], ['lowIron', 'Low-iron glass'],
    ['tempered', 'Tempered glass'], ['backSticker', 'Background sticker'], ['aquascape', 'Aquascape'],
    ['light', 'LED light'], ['cabinet', 'Cabinet'], ['canopy', 'Canopy']
  ];
  function tankOptionTags(o) {
    if (!o) return [];
    const tags = TANK_OPTIONS.filter(([k]) => o[k]).map(([, label]) => label);
    const holes = Math.round(Number(o.holes) || 0), dividers = Math.round(Number(o.dividers) || 0);
    if (holes > 0) tags.push(holes === 1 ? '1 hole' : `${holes} holes`);
    if (dividers > 0) tags.push(dividers === 1 ? '1 divider' : `${dividers} dividers`);
    String(o.extras || '').split(',').map((x) => x.trim().slice(0, 24)).filter(Boolean).slice(0, 6).forEach((x) => tags.push(x));
    return tags;
  }

  function create(canvas) {
    const ctx = canvas.getContext('2d');
    const media = {};
    let ad = null;

    // ---------- media ----------
    function loadMedia(src, type) {
      if (!src) return Promise.resolve(null);
      if (media[src]) return media[src].promise;
      const entry = { ready: false, failed: false };
      if (isVideo(src, type)) {
        const v = document.createElement('video');
        v.crossOrigin = 'anonymous'; v.muted = true; v.playsInline = true; v.preload = 'auto'; v.loop = true;
        v.src = src;
        entry.kind = 'video'; entry.el = v;
        entry.promise = new Promise((res) => {
          v.addEventListener('loadeddata', () => { entry.ready = true; res(entry); }, { once: true });
          v.addEventListener('error', () => { entry.failed = true; res(null); }, { once: true });
        });
      } else {
        const img = new Image();
        img.crossOrigin = 'anonymous';
        img.src = src;
        entry.kind = 'image'; entry.el = img;
        entry.promise = img.decode().then(() => { entry.ready = true; return entry; }, () => { entry.failed = true; return null; });
      }
      media[src] = entry;
      return entry.promise;
    }
    const getMedia = (src) => (src && media[src] && media[src].ready ? media[src] : null);
    const sceneMedia = (s) => (s.style === 'photo' ? getMedia(s.media) : null);

    function loadAll() {
      if (!ad) return Promise.resolve();
      return Promise.all(ad.scenes.map((s) => loadMedia(s.media, s.mediaType)).concat(loadMedia(ad.brand && ad.brand.logo)));
    }

    // ---------- timeline ----------
    function timeline() {
      let start = 0;
      return ad.scenes.map((s, i) => {
        const dur = Math.max(0.5, Number(s.duration) || 3);
        const x = { s, i, start, end: start + dur, dur, visStart: i > 0 ? start - FADE : 0 };
        start = x.end;
        return x;
      });
    }
    const totalDuration = () => (ad ? ad.scenes.reduce((a, s) => a + Math.max(0.5, Number(s.duration) || 3), 0) : 0);

    // ---------- drawing helpers ----------
    function wrap(text, maxW) {
      const words = String(text || '').split(/\s+/).filter(Boolean);
      const lines = [];
      let line = '';
      for (const w of words) {
        const test = line ? line + ' ' + w : w;
        if (ctx.measureText(test).width > maxW && line) { lines.push(line); line = w; } else line = test;
      }
      if (line) lines.push(line);
      return lines;
    }
    function roundRect(x, y, w, h, r) {
      ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r);
      ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath();
    }

    // ---------- the look: you are inside one of our tanks ----------
    // Caustics - the moving light net on a lit tank's floor - computed small (90x160) and scaled up,
    // so they're soft and cheap. Cached per frame time (the tide transition draws the water twice).
    const CW = 90, CH = 160;
    const causticCanvas = document.createElement('canvas');
    causticCanvas.width = CW; causticCanvas.height = CH;
    const causticCtx = causticCanvas.getContext('2d');
    const causticImg = causticCtx.createImageData(CW, CH);
    let causticTime = null;
    function caustics(t) {
      if (t === causticTime) return causticCanvas;
      causticTime = t;
      const d = causticImg.data;
      const time = t * 0.45 + 23;
      const ts = [0, 1, 2, 3].map((n) => time * (1 - 3.5 / (n + 1)));
      let k = 0;
      for (let y = 0; y < CH; y++) {
        const py = (y / CH) * 6.2832 * 1.6 - 250;
        const fall = 1 - (y / CH) * 0.7; // brighter near the surface
        for (let x = 0; x < CW; x++) {
          const px = (x / CW) * 6.2832 * 0.9 - 250;
          let ix = px, iy = py, c = 1;
          for (let n = 0; n < 4; n++) {
            const tt = ts[n];
            const nx = px + Math.cos(tt - ix) + Math.sin(tt + iy);
            const ny = py + Math.sin(tt - iy) + Math.cos(tt + ix);
            ix = nx; iy = ny;
            const a = px / (Math.sin(ix + tt) / 0.005), b = py / (Math.cos(iy + tt) / 0.005);
            c += 1 / Math.sqrt(a * a + b * b);
          }
          c = 1.17 - Math.pow(c / 4, 1.4);
          d[k] = 205; d[k + 1] = 245; d[k + 2] = 255;
          d[k + 3] = Math.min(255, Math.pow(Math.abs(c), 8) * 255 * fall);
          k += 4;
        }
      }
      causticCtx.putImageData(causticImg, 0, 0);
      return causticCanvas;
    }
    function drawCaustics(t, x, y, w, h, alpha) {
      ctx.save();
      ctx.globalCompositeOperation = 'lighter'; ctx.globalAlpha *= alpha;
      ctx.imageSmoothingEnabled = true; ctx.imageSmoothingQuality = 'high';
      ctx.drawImage(caustics(t), x, y, w, h);
      ctx.restore();
    }

    const SURFACE_Y = 150;
    const surfaceAt = (x, t) => SURFACE_Y + Math.sin(x * 0.011 + t * 1.6) * 9 + Math.sin(x * 0.027 - t * 2.3) * 4;

    function drawWater(t) {
      const g = ctx.createLinearGradient(0, 0, 0, H);
      g.addColorStop(0, '#0d6690'); g.addColorStop(0.4, '#06405f'); g.addColorStop(1, '#021624');
      ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
      drawCaustics(t, 0, 0, W, H, 0.5);

      // The water surface seen from below, rippling across the top.
      ctx.beginPath(); ctx.moveTo(0, 0);
      for (let x = 0; x <= W; x += 24) ctx.lineTo(x, surfaceAt(x, t));
      ctx.lineTo(W, 0); ctx.closePath();
      const air = ctx.createLinearGradient(0, 0, 0, SURFACE_Y + 12);
      air.addColorStop(0, 'rgba(190,240,255,0.32)'); air.addColorStop(1, 'rgba(190,240,255,0.12)');
      ctx.fillStyle = air; ctx.fill();
      ctx.beginPath();
      for (let x = 0; x <= W; x += 24) ctx[x ? 'lineTo' : 'moveTo'](x, surfaceAt(x, t));
      ctx.strokeStyle = 'rgba(235,252,255,0.55)'; ctx.lineWidth = 4; ctx.stroke();

      // Fine particles drifting in the water.
      ctx.fillStyle = 'rgba(220,242,255,0.28)';
      for (let i = 0; i < 46; i++) {
        const x = (rand(i + 70) * W + Math.sin(t * 0.35 + i) * 40 + W) % W;
        const y = SURFACE_Y + ((rand(i + 80) * (H - SURFACE_Y) + t * (rand(i + 90) - 0.5) * 30 + H) % (H - SURFACE_Y));
        ctx.beginPath(); ctx.arc(x, y, 1.5 + rand(i + 60) * 2.2, 0, TAU); ctx.fill();
      }

      // Two air-stone bubble streams rising from the bottom corners, popping at the surface.
      const span = H - SURFACE_Y + 60;
      for (const [sx, seed] of [[W * 0.09, 0], [W * 0.91, 50]]) {
        for (let i = 0; i < 20; i++) {
          const speed = 300 + rand(seed + i) * 140;
          const rise = (t * speed + rand(seed + i + 20) * span) % span;
          const y = H + 30 - rise;
          if (y < surfaceAt(sx, t) + 6) continue;
          const x = sx + Math.sin(rise * 0.018 + i) * (6 + rise * 0.025);
          const r = 3 + (rise / span) * 9 + rand(seed + i + 40) * 3;
          ctx.beginPath(); ctx.arc(x, y, r, 0, TAU);
          ctx.strokeStyle = 'rgba(215,248,255,0.5)'; ctx.lineWidth = 2; ctx.stroke();
          ctx.beginPath(); ctx.arc(x - r * 0.35, y - r * 0.35, r * 0.28, 0, TAU);
          ctx.fillStyle = 'rgba(255,255,255,0.6)'; ctx.fill();
        }
      }
    }

    // Over everything: the tank's front glass - black silicone seams on both sides and a faint glare
    // that passes now and then.
    function drawGlassFrame(t) {
      ctx.save();
      for (const x of [7, W - 7]) {
        ctx.fillStyle = 'rgba(8,12,16,0.75)'; ctx.fillRect(x - 5, 0, 10, H);
        ctx.fillStyle = 'rgba(255,255,255,0.18)'; ctx.fillRect(x - 1, 0, 2, H);
      }
      const edge = ctx.createLinearGradient(0, 0, 60, 0);
      edge.addColorStop(0, 'rgba(200,250,255,0.10)'); edge.addColorStop(1, 'rgba(200,250,255,0)');
      ctx.fillStyle = edge; ctx.fillRect(12, 0, 60, H);
      ctx.save(); ctx.translate(W, 0); ctx.scale(-1, 1); ctx.fillStyle = edge; ctx.fillRect(12, 0, 60, H); ctx.restore();
      const g = ((t + 2.5) % 7) / 1.6;
      if (g < 1) {
        const gx = -500 + g * (W + 1000);
        ctx.translate(gx, H / 2); ctx.rotate(-0.38);
        const band = ctx.createLinearGradient(-120, 0, 120, 0);
        band.addColorStop(0, 'rgba(255,255,255,0)'); band.addColorStop(0.5, 'rgba(255,255,255,0.09)'); band.addColorStop(1, 'rgba(255,255,255,0)');
        ctx.fillStyle = band; ctx.fillRect(-120, -H, 240, H * 2);
      }
      ctx.restore();
    }

    // The tide: everything below a rising, rippling waterline. q = 0 (bottom) .. 1 (covers the screen).
    const tideY = (x, q, t) => H * (1 - q) - 40 * q + Math.sin(x * 0.012 + t * 7) * 22 * Math.sin(Math.PI * q) + Math.sin(x * 0.031 - t * 5) * 8 * Math.sin(Math.PI * q);
    function tideClip(q, t) {
      ctx.beginPath(); ctx.moveTo(0, H);
      for (let x = 0; x <= W; x += 20) ctx.lineTo(x, tideY(x, q, t));
      ctx.lineTo(W, H); ctx.closePath(); ctx.clip();
    }
    function drawTideEdge(q, t) {
      if (q <= 0 || q >= 1) return;
      ctx.save();
      ctx.beginPath();
      for (let x = 0; x <= W; x += 20) ctx[x ? 'lineTo' : 'moveTo'](x, tideY(x, q, t));
      ctx.shadowColor = 'rgba(200,250,255,0.9)'; ctx.shadowBlur = 18;
      ctx.strokeStyle = 'rgba(240,253,255,0.95)'; ctx.lineWidth = 6; ctx.stroke();
      ctx.shadowBlur = 0;
      // Foam: bubbles riding just under the line.
      for (let i = 0; i < 40; i++) {
        const x = rand(i + 200) * W;
        const y = tideY(x, q, t) + 10 + rand(i + 240) * 90;
        const r = 2 + rand(i + 280) * 7;
        ctx.beginPath(); ctx.arc(x, y, r, 0, TAU);
        ctx.strokeStyle = `rgba(230,250,255,${0.7 * (1 - rand(i + 300) * 0.5)})`; ctx.lineWidth = 2; ctx.stroke();
      }
      ctx.restore();
    }

    // Concentric ripples spreading from a circle (logo scene and end card).
    function drawRipples(cx, cy, r, t, alpha) {
      ctx.save();
      for (let k = 0; k < 3; k++) {
        const p = (t * 0.55 + k / 3) % 1;
        ctx.beginPath(); ctx.arc(cx, cy, r + 14 + p * r * 1.15, 0, TAU);
        ctx.strokeStyle = withAlpha(ad.accent, 0.55 * (1 - p) * alpha); ctx.lineWidth = 5 * (1 - p) + 1; ctx.stroke();
      }
      ctx.restore();
    }

    // ---------- the clownfish that swims in the tank drawing, drawn nose-right around (0,0) ----------
    const TAU = Math.PI * 2;

    function fishEye(x, y, r, iris) {
      ctx.beginPath(); ctx.arc(x, y, r, 0, TAU); ctx.fillStyle = iris || '#f4f1e6'; ctx.fill();
      ctx.beginPath(); ctx.arc(x + r * 0.12, y, r * 0.62, 0, TAU); ctx.fillStyle = '#0b0f14'; ctx.fill();
      ctx.beginPath(); ctx.arc(x + r * 0.32, y - r * 0.3, r * 0.22, 0, TAU); ctx.fillStyle = 'rgba(255,255,255,0.9)'; ctx.fill();
    }
    // Streamlined body: nose at +L/2, tail joint at -L/2 (its half-height = taper * H / 2).
    function bodyPath(L, H, taper) {
      const n = L / 2, p = -L / 2, ph = H * taper / 2;
      ctx.beginPath();
      ctx.moveTo(n, 0);
      ctx.bezierCurveTo(n, -H * 0.42, n - L * 0.32, -H * 0.55, 0, -H * 0.5);
      ctx.bezierCurveTo(-L * 0.3, -H * 0.45, p + L * 0.1, -ph, p, -ph);
      ctx.lineTo(p, ph);
      ctx.bezierCurveTo(p + L * 0.1, ph, -L * 0.3, H * 0.45, 0, H * 0.5);
      ctx.bezierCurveTo(n - L * 0.32, H * 0.55, n, H * 0.42, n, 0);
      ctx.closePath();
    }
    // Light from above: brighter back, darker belly. Call while clipped to the body.
    function bodyShade(L, H) {
      const g = ctx.createLinearGradient(0, -H / 2, 0, H / 2);
      g.addColorStop(0, 'rgba(255,255,255,0.35)'); g.addColorStop(0.45, 'rgba(255,255,255,0)'); g.addColorStop(1, 'rgba(0,0,0,0.28)');
      ctx.fillStyle = g; ctx.fillRect(-L, -H, L * 2, H * 2);
    }
    function fillBody(L, H, taper, top, bottom, pattern) {
      bodyPath(L, H, taper);
      const g = ctx.createLinearGradient(0, -H / 2, 0, H / 2);
      g.addColorStop(0, top); g.addColorStop(1, bottom);
      ctx.fillStyle = g; ctx.fill();
      ctx.save(); bodyPath(L, H, taper); ctx.clip();
      if (pattern) pattern();
      bodyShade(L, H);
      ctx.restore();
    }
    // Tail fin hinged at x, swinging by `wag`. round=true for a fan, false for a fork.
    function tailFin(x, wag, len, spread, round, fill, edge) {
      ctx.save(); ctx.translate(x, 0); ctx.rotate(wag);
      ctx.beginPath();
      ctx.moveTo(6, -spread * 0.18);
      ctx.quadraticCurveTo(-len * 0.45, -spread * 0.95, -len, -spread);
      if (round) ctx.quadraticCurveTo(-len * 1.25, 0, -len, spread);
      else ctx.quadraticCurveTo(-len * 0.55, 0, -len, spread);
      ctx.quadraticCurveTo(-len * 0.45, spread * 0.95, 6, spread * 0.18);
      ctx.closePath();
      ctx.fillStyle = fill; ctx.fill();
      if (edge) { ctx.strokeStyle = edge; ctx.lineWidth = 3; ctx.stroke(); }
      ctx.strokeStyle = 'rgba(0,0,0,0.12)'; ctx.lineWidth = 1.2;
      for (let k = -2; k <= 2; k++) { ctx.beginPath(); ctx.moveTo(2, k * spread * 0.06); ctx.lineTo(-len * 0.92, k * spread * 0.42); ctx.stroke(); }
      ctx.restore();
    }
    function finShape(points, fill, edge) {
      ctx.beginPath(); ctx.moveTo(points[0][0], points[0][1]);
      for (let i = 1; i < points.length - 1; i += 2) ctx.quadraticCurveTo(points[i][0], points[i][1], points[i + 1][0], points[i + 1][1]);
      ctx.closePath(); ctx.fillStyle = fill; ctx.fill();
      if (edge) { ctx.strokeStyle = edge; ctx.lineWidth = 3; ctx.stroke(); }
    }

    const SPECIES = {
      clown(t, ph) {
        const L = 120, H = 64, wag = Math.sin(t * 7 + ph) * 0.25, fl = Math.sin(t * 9 + ph) * 0.3;
        const orange = '#ff8a1f', edge = '#1a1110';
        tailFin(-L / 2 + 4, wag, 34, 26, true, orange, edge);
        finShape([[-34, -H * 0.42], [-30, -H * 0.85], [-8, -H * 0.62], [8, -H * 0.85], [22, -H * 0.44]], orange, edge);
        finShape([[-30, H * 0.4], [-36, H * 0.78], [-10, H * 0.45]], orange, edge);
        fillBody(L, H, 0.42, '#ffa040', '#e45a05', () => {
          for (const [bx, bw] of [[L * 0.2, 15], [-4, 17], [-L * 0.43, 10]]) {
            ctx.beginPath(); ctx.ellipse(bx, 0, bw, H * 0.62, 0, 0, TAU);
            ctx.fillStyle = '#fbfbf7'; ctx.fill(); ctx.strokeStyle = edge; ctx.lineWidth = 3.5; ctx.stroke();
          }
        });
        bodyPath(L, H, 0.42); ctx.strokeStyle = 'rgba(0,0,0,0.35)'; ctx.lineWidth = 2; ctx.stroke();
        // Pectoral fin low on the belly, sweeping back - kept clear of the head band.
        ctx.save(); ctx.translate(L * 0.02, H * 0.3); ctx.rotate(0.35 + fl * 0.5);
        ctx.lineWidth = 2;
        finShape([[0, 0], [-10, 16], [-22, 10]], 'rgba(255,150,50,0.9)', 'rgba(26,17,16,0.6)'); ctx.restore();
        fishEye(L * 0.36, -H * 0.1, 7);
      },
    };

    function drawFish(species, x, y, size, dir, t, ph) {
      ctx.save();
      ctx.translate(x, y);
      ctx.scale(dir * size * 1.5, size * 1.5);
      SPECIES[species](t, ph);
      ctx.restore();
    }

    // ---------- tank / stand / sump: one 3D box drawn to the real length x width x height ----------
    const DEFAULT_DIMS = { tank: [48, 18, 20], stand: [48, 18, 30], sump: [30, 14, 16] };

    function dimsOf(s) {
      const fallback = DEFAULT_DIMS[s.style] || DEFAULT_DIMS.tank;
      const d = Array.isArray(s.dims) ? s.dims : fallback;
      return fallback.map((f, i) => Math.max(1, Number(d[i]) || f));
    }

    // Fits the box into maxW x maxH with its back-top edge at y=top. at(u, v, w) is the point
    // u along the length, v down the height and w into the depth (each 0..1).
    function boxGeom(dims, top, maxW, maxH) {
      const [L, Wd, Ht] = dims;
      const cx = Math.cos(0.62) * 0.55, sy = Math.sin(0.62) * 0.55;
      const k = Math.min(maxW / (L + Wd * cx), maxH / (Ht + Wd * sy));
      const fw = L * k, fh = Ht * k, dx = Wd * k * cx, dy = -Wd * k * sy;
      const x0 = (W - fw - dx) / 2, y0 = top - dy;
      const at = (u, v, w) => [x0 + fw * u + dx * w, y0 + fh * v + dy * w];
      return { L, Wd, Ht, k, fw, fh, dx, dy, x0, y0, at };
    }

    // The 12 glass edges, back first, in the order they draw themselves.
    function boxEdges(g) {
      const a = g.at;
      return [
        [a(0, 0, 1), a(1, 0, 1)], [a(1, 0, 1), a(1, 1, 1)], [a(1, 1, 1), a(0, 1, 1)], [a(0, 1, 1), a(0, 0, 1)],
        [a(0, 0, 0), a(0, 0, 1)], [a(1, 0, 0), a(1, 0, 1)], [a(1, 1, 0), a(1, 1, 1)], [a(0, 1, 0), a(0, 1, 1)],
        [a(0, 0, 0), a(1, 0, 0)], [a(1, 0, 0), a(1, 1, 0)], [a(1, 1, 0), a(0, 1, 0)], [a(0, 1, 0), a(0, 0, 0)]
      ];
    }

    // Draws segments one after another; p = how many are done (fractional = part-way).
    function revealSegments(segs, p, stroke) {
      segs.forEach(([a, b], i) => {
        const k = clamp(p - i);
        if (k <= 0) return;
        stroke(a, [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k]);
      });
    }
    const glassStroke = (a, b) => {
      ctx.lineCap = 'round'; ctx.strokeStyle = 'rgba(200,250,255,0.95)'; ctx.lineWidth = 7;
      ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]); ctx.stroke();
    };
    function poly(points) {
      ctx.beginPath(); ctx.moveTo(points[0][0], points[0][1]);
      for (let i = 1; i < points.length; i++) ctx.lineTo(points[i][0], points[i][1]);
      ctx.closePath();
    }

    // Water up to height v (0 = top, 1 = bottom): front + side faces, plus the lit surface.
    function drawWaterIn(g, v) {
      const a = g.at;
      const wg = ctx.createLinearGradient(0, a(0, v, 0)[1], 0, a(0, 1, 0)[1]);
      wg.addColorStop(0, withAlpha(ad.accent, 0.55)); wg.addColorStop(1, 'rgba(20,120,170,0.6)');
      ctx.fillStyle = wg;
      poly([a(0, v, 0), a(1, v, 0), a(1, v, 1), a(1, 1, 1), a(1, 1, 0), a(0, 1, 0)]); ctx.fill();
      ctx.fillStyle = 'rgba(180,255,240,0.35)';
      poly([a(0, v, 0), a(1, v, 0), a(1, v, 1), a(0, v, 1)]); ctx.fill();
    }

    // A part of a taller box (canopy / tank / cabinet stacked): heights v0..v1 of g, Ht inches tall.
    function subGeom(g, v0, v1, Ht) {
      return Object.assign({}, g, { Ht, fh: g.fh * (v1 - v0), y0: g.y0 + g.fh * v0, at: (u, v, w) => g.at(u, v0 + (v1 - v0) * v, w) });
    }

    // bottomY = where the length label goes under (the cabinet's foot when there is one).
    function drawDimLabels(g, lt, bottomY) {
      const k = easeOut((lt - 0.5) / 1.3);
      if (k <= 0) return;
      ctx.save(); ctx.globalAlpha *= clamp(k * 2);
      ctx.font = `800 54px ${FONT}`; ctx.fillStyle = '#ffd166'; ctx.textBaseline = 'middle';
      ctx.shadowColor = 'rgba(0,0,0,0.45)'; ctx.shadowBlur = 10;
      ctx.textAlign = 'center'; ctx.fillText(`${Math.round(g.L * k)}"`, g.x0 + g.fw / 2, (bottomY == null ? g.y0 + g.fh : bottomY) + 60);
      ctx.textAlign = 'right'; ctx.fillText(`${Math.round(g.Ht * k)}"`, g.x0 - 30, g.y0 + g.fh / 2);
      ctx.textAlign = 'left'; ctx.fillText(`${Math.round(g.Wd * k)}"`, g.x0 + g.fw + g.dx / 2 + 30, g.y0 + g.fh + g.dy / 2 + 10);
      ctx.restore();
    }

    // Closed box faces (front, top, right side) - cabinet and canopy.
    function drawPanelBox(a) {
      const faces = [
        [[a(0, 0, 0), a(1, 0, 0), a(1, 0, 1), a(0, 0, 1)], '#2b333a'],
        [[a(1, 0, 0), a(1, 0, 1), a(1, 1, 1), a(1, 1, 0)], '#14181c'],
        [[a(0, 0, 0), a(1, 0, 0), a(1, 1, 0), a(0, 1, 0)], '#1f252b']
      ];
      for (const [q, fill] of faces) {
        poly(q); ctx.fillStyle = fill; ctx.fill();
        ctx.strokeStyle = 'rgba(255,255,255,0.18)'; ctx.lineWidth = 2; ctx.stroke();
      }
    }

    // Cabinet under the tank: rises from the floor; doors (2 per 36" like the calculator) with handles.
    function drawCabinet(cg, k, L) {
      if (k <= 0) return;
      const a = cg.at;
      ctx.save(); ctx.globalAlpha *= clamp(k * 1.5);
      ctx.translate(0, (1 - k) * 60);
      drawPanelBox(a);
      const doors = 2 * Math.max(1, Math.round(L / 36));
      ctx.strokeStyle = 'rgba(0,0,0,0.55)'; ctx.lineWidth = 3;
      for (let i = 1; i < doors; i++) {
        const [x1, y1] = a(i / doors, 0.05, 0), [x2, y2] = a(i / doors, 0.92, 0);
        ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
      }
      const [kx1, ky1] = a(0, 0.92, 0), [kx2, ky2] = a(1, 1, 0);
      ctx.fillStyle = '#0e1114'; ctx.fillRect(kx1, ky1, kx2 - kx1, ky2 - ky1);
      ctx.fillStyle = '#c9d0d5';
      for (let i = 0; i < doors; i++) {
        const u = i % 2 === 0 ? (i + 1) / doors - 0.03 : i / doors + 0.03;
        const [hx, hy1] = a(u, 0.38, 0), [, hy2] = a(u, 0.56, 0);
        ctx.fillRect(hx - 3, hy1, 6, hy2 - hy1);
      }
      ctx.restore();
    }

    function drawTank(s, lt, top, maxH) {
      const o = s.options || {};
      const [L, Wd, Ht] = dimsOf(s);
      const canH = o.canopy ? clamp(Ht * 0.45, 6, 12) : 0;
      const cabH = o.cabinet ? 30 : 0;
      const total = canH + Ht + cabH;
      const full = boxGeom([L, Wd, total], top, 720, maxH);
      const g = subGeom(full, canH / total, (canH + Ht) / total, Ht);
      const a = g.at;
      const frame = easeInOut((lt - 0.2) / 1.4);
      const wl = easeOut((lt - 1.4) / 0.9);
      const parts = clamp((lt - 1.2) / 0.4);
      const dividers = Math.round(clamp(Number(o.dividers) || 0, 0, 3));
      const holes = Math.round(clamp(Number(o.holes) || 0, 0, 4));

      if (cabH) drawCabinet(subGeom(full, (canH + Ht) / total, 1, cabH), frame, L);
      if (o.backSticker && frame > 0) {
        ctx.save(); ctx.globalAlpha *= clamp(frame * 1.5);
        const bg = ctx.createLinearGradient(0, a(0, 0, 1)[1], 0, a(0, 1, 1)[1]);
        bg.addColorStop(0, '#0b2a44'); bg.addColorStop(1, '#03080d');
        poly([a(0, 0, 1), a(1, 0, 1), a(1, 1, 1), a(0, 1, 1)]); ctx.fillStyle = bg; ctx.fill();
        ctx.restore();
      }
      ctx.fillStyle = 'rgba(190,240,255,0.08)'; ctx.fillRect(g.x0, g.y0, g.fw, g.fh);

      if (wl > 0) drawWaterIn(g, 1 - 0.9 * wl);

      // AIO: black rear filter chamber with its overflow slots (over the water tint so it reads as solid).
      if (o.aio && parts > 0) {
        ctx.save(); ctx.globalAlpha *= parts;
        poly([a(0, 0.08, 0.8), a(1, 0.08, 0.8), a(1, 1, 0.8), a(0, 1, 0.8)]);
        ctx.fillStyle = 'rgba(8,12,16,0.85)'; ctx.fill();
        ctx.strokeStyle = 'rgba(200,250,255,0.6)'; ctx.lineWidth = 3; ctx.stroke();
        const [sx0, sy0] = a(0.6, 0.13, 0.8), [sx1, sy1] = a(0.94, 0.27, 0.8);
        const sw = (sx1 - sx0) / 13;
        ctx.fillStyle = 'rgba(160,220,240,0.5)';
        for (let i = 0; i < 7; i++) ctx.fillRect(sx0 + i * 2 * sw, sy0, sw, sy1 - sy0);
        ctx.restore();
      }

      // LED light beams down into the water once the light switches on.
      const lightOn = o.light ? easeOut((lt - 2.0) / 0.4) : 0;
      if (lightOn > 0) {
        ctx.save(); ctx.globalAlpha *= lightOn * (0.85 + 0.15 * Math.sin(lt * 9));
        const [bx1, by] = a(0.06, 0, 0.5), [bx2] = a(0.94, 0, 0.5), [, fy] = a(0, 1, 0.5);
        const beam = ctx.createLinearGradient(0, by, 0, fy);
        beam.addColorStop(0, 'rgba(255,255,240,0.32)'); beam.addColorStop(1, 'rgba(255,255,240,0)');
        ctx.fillStyle = beam;
        poly([[bx1, by], [bx2, by], [bx2 + 30, fy], [bx1 - 30, fy]]); ctx.fill();
        ctx.restore();
      }

      // Aquascape: sand, plants growing up and swaying, two rocks.
      if (o.aquascape) {
        const k = easeOut((lt - 1.6) / 0.8);
        if (k > 0) {
          ctx.save(); ctx.globalAlpha *= clamp(k * 2);
          const sv = 1 - clamp(2.5 / Ht, 0.05, 0.12);
          poly([a(0, sv, 0), a(1, sv, 0), a(1, 1, 0), a(0, 1, 0)]); ctx.fillStyle = '#cdb27a'; ctx.fill();
          poly([a(0, sv, 0), a(1, sv, 0), a(1, sv, 1), a(0, sv, 1)]); ctx.fillStyle = '#e3cd98'; ctx.fill();
          ctx.lineCap = 'round';
          [[0.08, 0.55], [0.13, 0.42], [0.42, 0.5], [0.48, 0.36], [0.83, 0.6], [0.9, 0.45]].forEach(([u, h], i) => {
            const [px, py] = a(u, sv, 0.6);
            const ph = g.fh * h * k, sway = Math.sin(lt * 1.8 + i) * 14 * k;
            ctx.strokeStyle = i % 2 ? '#3fae5a' : '#2e8b47'; ctx.lineWidth = clamp(g.k * 0.8, 5, 10);
            ctx.beginPath(); ctx.moveTo(px, py); ctx.quadraticCurveTo(px - sway, py - ph * 0.5, px + sway, py - ph); ctx.stroke();
          });
          const rr = g.fw * 0.07 * k;
          for (const u of [0.28, 0.66]) {
            const [rx, ry] = a(u, sv, 0.45);
            ctx.beginPath(); ctx.ellipse(rx, ry - rr * 0.35, rr * 1.2, rr * 0.75, 0, Math.PI, TAU); ctx.closePath();
            ctx.fillStyle = '#6f7a80'; ctx.fill();
            ctx.beginPath(); ctx.ellipse(rx - rr * 0.3, ry - rr * 0.7, rr * 0.45, rr * 0.2, -0.3, 0, TAU);
            ctx.fillStyle = 'rgba(255,255,255,0.18)'; ctx.fill();
          }
          ctx.restore();
        }
      }

      // Dividers: glass panes across the width, splitting the tank into equal sections.
      if (dividers && parts > 0) {
        ctx.save(); ctx.globalAlpha *= parts;
        for (let i = 1; i <= dividers; i++) {
          const u = i / (dividers + 1);
          poly([a(u, 0.02, 0), a(u, 1, 0), a(u, 1, 1), a(u, 0.02, 1)]);
          ctx.fillStyle = 'rgba(200,250,255,0.16)'; ctx.fill();
          ctx.strokeStyle = 'rgba(200,250,255,0.85)'; ctx.lineWidth = 4; ctx.stroke();
        }
        ctx.restore();
      }

      // Drilled holes with bulkheads on the back glass, popping in one by one.
      if (holes) {
        const r = clamp(g.k * 0.8, 7, 13);
        for (let i = 0; i < holes; i++) {
          const k = easeOut((lt - 1.6 - i * 0.15) / 0.3);
          if (k <= 0) continue;
          const [hx, hy] = a(0.9 - i * 0.07, 0.22, o.aio ? 0.8 : 1);
          ctx.beginPath(); ctx.arc(hx, hy, r * 1.4 * k, 0, TAU); ctx.fillStyle = '#c9d0d5'; ctx.fill();
          ctx.beginPath(); ctx.arc(hx, hy, r * k, 0, TAU); ctx.fillStyle = '#10161b'; ctx.fill();
        }
      }

      if (wl >= 1) {
        const size = clamp(g.fh / 640, 0.3, 0.7);
        const swim = Math.max(1, g.fw / (dividers + 1) - 220 * size);
        drawFish('clown', g.x0 + 110 * size + ((lt - 2.3) * 160) % swim, g.y0 + g.fh * 0.62, size, 1, lt, 3);
      }
      revealSegments(boxEdges(g), frame * 12, glassStroke);

      // High strip: a glass band right round the top.
      if (o.highStrip && parts > 0) {
        const hv = clamp(1.5 / Ht, 0.03, 0.12);
        ctx.save(); ctx.globalAlpha *= parts;
        ctx.fillStyle = 'rgba(170,235,255,0.35)'; ctx.strokeStyle = 'rgba(220,250,255,0.9)'; ctx.lineWidth = 3;
        for (const q of [
          [a(0, 0, 1), a(1, 0, 1), a(1, hv, 1), a(0, hv, 1)], [a(0, 0, 0), a(0, 0, 1), a(0, hv, 1), a(0, hv, 0)],
          [a(1, 0, 0), a(1, 0, 1), a(1, hv, 1), a(1, hv, 0)], [a(0, 0, 0), a(1, 0, 0), a(1, hv, 0), a(0, hv, 0)]
        ]) { poly(q); ctx.fill(); ctx.stroke(); }
        ctx.restore();
      }

      // The light fixture sits over the tank (hidden inside the canopy when there is one).
      if (o.light && !canH && parts > 0) {
        ctx.save(); ctx.globalAlpha *= parts;
        const [bx1, by] = a(0.04, 0, 0.5), [bx2] = a(0.96, 0, 0.5);
        const bh = clamp(g.k * 1.2, 10, 18);
        roundRect(bx1, by - bh - 14, bx2 - bx1, bh, bh / 2); ctx.fillStyle = '#20262c'; ctx.fill();
        ctx.fillStyle = lightOn > 0 ? `rgba(255,255,235,${0.4 + 0.6 * lightOn})` : '#3a424a';
        ctx.fillRect(bx1 + bh, by - 16, bx2 - bx1 - bh * 2, 4);
        ctx.fillStyle = '#20262c'; ctx.fillRect(bx1 + 6, by - 14, 5, 14); ctx.fillRect(bx2 - 11, by - 14, 5, 14);
        ctx.restore();
      }

      // Canopy drops onto the tank.
      if (canH) {
        const k = easeOut((lt - 1.7) / 0.5);
        if (k > 0) {
          ctx.save(); ctx.globalAlpha *= clamp(k * 1.5);
          ctx.translate(0, -(1 - k) * 120);
          drawPanelBox(subGeom(full, 0, canH / total, canH).at);
          ctx.restore();
        }
      }

      drawDimLabels(g, lt, full.y0 + full.fh);
      drawOptionTags(tankOptionTags(o), lt, full.y0 + full.fh + 100);
    }

    // Tank options as pills under the drawing (up to 2 rows, smaller text when there are many),
    // popping in one after another.
    function drawOptionTags(tags, lt, y) {
      if (!tags.length) return;
      ctx.save();
      ctx.textBaseline = 'middle'; ctx.textAlign = 'left';
      let rows, fs, padX, h, gap;
      for (fs of [30, 25, 21]) {
        padX = Math.round(fs * 0.67); h = Math.round(fs * 1.8); gap = Math.round(fs * 0.4);
        ctx.font = `700 ${fs}px ${FONT}`;
        rows = [[]];
        let rowW = 0, fits = true;
        for (const label of tags) {
          const w = ctx.measureText(label).width + padX * 2 + 24;
          if (rowW + w > 980 && rows[rows.length - 1].length) {
            if (rows.length === 2) { fits = false; break; }
            rows.push([]); rowW = 0;
          }
          rows[rows.length - 1].push({ label, w }); rowW += w + gap;
        }
        if (fits) break;
      }
      let n = 0;
      rows.forEach((row, r) => {
        let x = (W - (row.reduce((sum, it) => sum + it.w, 0) + gap * (row.length - 1))) / 2;
        const cy = y + r * (h + gap) + h / 2;
        for (const it of row) {
          const k = easeOut((lt - 1.0 - n++ * 0.12) / 0.35);
          if (k > 0) {
            ctx.save(); ctx.globalAlpha *= clamp(k * 1.5);
            ctx.translate(x + it.w / 2, cy); ctx.scale(0.7 + 0.3 * k, 0.7 + 0.3 * k);
            roundRect(-it.w / 2, -h / 2, it.w, h, h / 2); ctx.fillStyle = 'rgba(2,22,37,0.85)'; ctx.fill();
            ctx.strokeStyle = withAlpha(ad.accent, 0.9); ctx.lineWidth = 3; ctx.stroke();
            ctx.beginPath(); ctx.arc(-it.w / 2 + padX + 6, 0, 7, 0, TAU); ctx.fillStyle = ad.accent; ctx.fill();
            ctx.fillStyle = '#ffffff'; ctx.fillText(it.label, -it.w / 2 + padX + 22, 1);
            ctx.restore();
          }
          x += it.w + gap;
        }
      });
      ctx.restore();
    }

    // Square-tube metal stand: legs first, then each layer's frame (with its centre support bar).
    function drawStand(s, lt, top, maxH) {
      const g = boxGeom(dimsOf(s), top, 720, maxH);
      const a = g.at;
      const layers = Math.round(clamp(Number(s.layers) || 2, 1, 4));
      const levels = layers === 1 ? [0] : Array.from({ length: layers }, (_, i) => (i * 0.9) / (layers - 1));
      const white = s.paint === 'white';
      const tube = clamp(g.k * 1.3, 9, 18);
      const segs = [
        [a(0, 0, 1), a(0, 1, 1)], [a(1, 0, 1), a(1, 1, 1)],
        ...levels.flatMap((v) => [[a(0, v, 1), a(1, v, 1)], [a(0, v, 0), a(0, v, 1)], [a(1, v, 0), a(1, v, 1)], [a(0.5, v, 0), a(0.5, v, 1)]]),
        [a(0, 0, 0), a(0, 1, 0)], [a(1, 0, 0), a(1, 1, 0)],
        ...levels.map((v) => [a(0, v, 0), a(1, v, 0)])
      ];
      const p = easeInOut((lt - 0.2) / 1.6) * segs.length;
      revealSegments(segs, p, (from, to) => {
        ctx.lineCap = 'square';
        ctx.strokeStyle = white ? 'rgba(0,0,0,0.35)' : 'rgba(255,255,255,0.28)'; ctx.lineWidth = tube + 4;
        ctx.beginPath(); ctx.moveTo(from[0], from[1]); ctx.lineTo(to[0], to[1]); ctx.stroke();
        ctx.strokeStyle = white ? '#eef1f3' : '#16191d'; ctx.lineWidth = tube;
        ctx.beginPath(); ctx.moveTo(from[0], from[1]); ctx.lineTo(to[0], to[1]); ctx.stroke();
        // Highlight along the lit side of the tube (up for bars, left for legs), never past its ends.
        const len = Math.hypot(to[0] - from[0], to[1] - from[1]) || 1;
        let nx = (to[1] - from[1]) / len, ny = -(to[0] - from[0]) / len;
        if (ny > 0 || (ny === 0 && nx > 0)) { nx = -nx; ny = -ny; }
        const off = tube * 0.22;
        ctx.strokeStyle = white ? '#ffffff' : 'rgba(255,255,255,0.22)'; ctx.lineWidth = Math.max(2, tube * 0.22); ctx.lineCap = 'butt';
        ctx.beginPath(); ctx.moveTo(from[0] + nx * off, from[1] + ny * off); ctx.lineTo(to[0] + nx * off, to[1] + ny * off); ctx.stroke();
      });
      if (p >= segs.length) {
        ctx.fillStyle = white ? '#c9d0d5' : '#0b0d10';
        for (const [u, w] of [[0, 1], [1, 1], [0, 0], [1, 0]]) {
          const [fx, fy] = a(u, 1, w);
          ctx.fillRect(fx - tube * 0.75, fy, tube * 1.5, tube * 0.7);
        }
      }
      drawDimLabels(g, lt);
    }

    // Sump: glass box with baffles; filter sock -> bio media -> return pump, water flowing through.
    function drawSump(s, lt, top, maxH) {
      const g = boxGeom(dimsOf(s), top, 720, maxH);
      const a = g.at;
      const wl = easeOut((lt - 1.4) / 0.9);
      const waterTop = 1 - 0.72 * wl;
      if (wl > 0) drawWaterIn(g, waterTop);
      ctx.fillStyle = 'rgba(190,240,255,0.08)'; ctx.fillRect(g.x0, g.y0, g.fw, g.fh);

      // Baffles: under (gap at the bottom), over, over - drawn as panes running front to back.
      const baffleAlpha = clamp((lt - 1.2) / 0.4);
      if (baffleAlpha > 0) {
        ctx.save(); ctx.globalAlpha *= baffleAlpha;
        for (const [u, v1, v2] of [[0.32, 0.03, 0.82], [0.37, 0.34, 1], [0.7, 0.3, 1]]) {
          poly([a(u, v1, 0), a(u, v2, 0), a(u, v2, 1), a(u, v1, 1)]);
          ctx.fillStyle = 'rgba(200,250,255,0.16)'; ctx.fill();
          ctx.strokeStyle = 'rgba(200,250,255,0.85)'; ctx.lineWidth = 4; ctx.stroke();
        }
        ctx.restore();
      }

      const c = easeOut((lt - 1.9) / 0.5);
      if (c > 0) {
        ctx.save(); ctx.globalAlpha *= c;
        // Filter sock hanging in the first chamber.
        const [sx1, sy1] = a(0.07, -0.02, 0.5), [sx2, sy2] = a(0.25, 0.62, 0.5);
        const sr = Math.min((sx2 - sx1) / 2, 40);
        ctx.beginPath(); ctx.moveTo(sx1, sy1); ctx.lineTo(sx2, sy1); ctx.lineTo(sx2, sy2 - sr);
        ctx.arc((sx1 + sx2) / 2, sy2 - sr, (sx2 - sx1) / 2, 0, Math.PI); ctx.closePath();
        ctx.fillStyle = 'rgba(246,246,242,0.92)'; ctx.fill();
        ctx.strokeStyle = 'rgba(150,160,165,0.6)'; ctx.lineWidth = 1.5;
        for (let y = sy1 + 12; y < sy2 - 6; y += 12) { ctx.beginPath(); ctx.moveTo(sx1 + 4, y); ctx.lineTo(sx2 - 4, y); ctx.stroke(); }
        ctx.fillStyle = '#d7dde1'; ctx.fillRect(sx1 - 6, sy1 - 6, sx2 - sx1 + 12, 10);
        // Bio media balls in the middle chamber.
        const r = clamp(g.k * 0.9, 6, 13);
        const MEDIA = ['#cfd6db', '#8fb5c8', '#e6d6a8', '#b9c7a4'];
        const [mx1, my1] = a(0.4, 0.45, 0.5), [mx2, my2] = a(0.67, 0.97, 0.5);
        let n = 0;
        for (let y = my2 - r; y > my1; y -= r * 1.7) {
          for (let x = mx1 + r + ((n % 2) * r); x < mx2 - r; x += r * 2.1) {
            ctx.beginPath(); ctx.arc(x, y, r, 0, TAU); ctx.fillStyle = MEDIA[(n * 7 + Math.round(x)) % MEDIA.length]; ctx.fill();
            ctx.strokeStyle = 'rgba(0,0,0,0.25)'; ctx.lineWidth = 1.5; ctx.stroke();
          }
          n++;
        }
        // Return pump with its pipe going up and out.
        const [px1, py1] = a(0.76, 0.74, 0.5), [px2, py2] = a(0.93, 0.99, 0.5);
        const pipe = clamp(g.k * 1.1, 8, 14);
        const [pipeX] = a(0.845, 0, 0.5);
        ctx.strokeStyle = '#d9dee2'; ctx.lineWidth = pipe; ctx.lineCap = 'butt';
        ctx.beginPath(); ctx.moveTo(pipeX, py1); ctx.lineTo(pipeX, a(0, -0.35, 0.5)[1]); ctx.stroke();
        roundRect(px1, py1, px2 - px1, py2 - py1, 8); ctx.fillStyle = '#2a2f36'; ctx.fill();
        ctx.fillStyle = ad.accent; ctx.fillRect(px1 + 6, py1 + (py2 - py1) * 0.4, px2 - px1 - 12, 5);
        ctx.restore();
      }

      // Water flowing through: down the sock, under/over the baffles, into the pump and up the pipe.
      if (wl >= 1) {
        const path = [[0.16, 0.2], [0.16, 0.9], [0.345, 0.92], [0.345, 0.34], [0.42, 0.31], [0.66, 0.31], [0.75, 0.33], [0.845, 0.72], [0.845, -0.3]]
          .map(([u, v]) => a(u, v, 0.5));
        const lens = path.slice(1).map((pt, i) => Math.hypot(pt[0] - path[i][0], pt[1] - path[i][1]));
        const total = lens.reduce((x, y) => x + y, 0);
        for (let i = 0; i < 14; i++) {
          let d = ((lt - 2.3) * 220 + (i * total) / 14) % total;
          let seg = 0;
          while (seg < lens.length - 1 && d > lens[seg]) { d -= lens[seg]; seg++; }
          const f = clamp(d / lens[seg]);
          const x = path[seg][0] + (path[seg + 1][0] - path[seg][0]) * f;
          const y = path[seg][1] + (path[seg + 1][1] - path[seg][1]) * f;
          ctx.beginPath(); ctx.arc(x, y, 5, 0, TAU); ctx.fillStyle = 'rgba(255,255,255,0.85)'; ctx.fill();
        }
      }
      revealSegments(boxEdges(g), easeInOut((lt - 0.2) / 1.4) * 12, glassStroke);
      drawDimLabels(g, lt);
      // Chamber names as small tags above the back top edge, drawn last so the glass never crosses them.
      if (c > 0) {
        ctx.save(); ctx.globalAlpha *= c;
        const fs = Math.round(clamp(g.fw * 0.042, 18, 28));
        ctx.font = `700 ${fs}px ${FONT}`; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
        const ly = a(0, 0, 1)[1];
        for (const [u, label] of [[0.16, 'Filter'], [0.535, 'Media'], [0.845, 'Pump']]) {
          const lx = a(u, 0, 0.5)[0]; // centred over the part, which sits mid-depth
          const tw = ctx.measureText(label).width + fs;
          roundRect(lx - tw / 2, ly - fs * 2.2, tw, fs * 1.6, fs * 0.8);
          ctx.fillStyle = 'rgba(2,22,37,0.85)'; ctx.fill();
          ctx.fillStyle = '#ffffff'; ctx.fillText(label, lx, ly - fs * 1.4 + 1);
        }
        ctx.restore();
      }
    }

    // Photo/clip full screen. It arrives rippling as if seen through moving water, settles, then
    // drifts slowly sideways, with the tank's caustic light playing over it.
    function drawMediaBg(m, lt, dur, t) {
      const el = m.el;
      const iw = m.kind === 'video' ? el.videoWidth : el.naturalWidth;
      const ih = m.kind === 'video' ? el.videoHeight : el.naturalHeight;
      if (!iw || !ih) return;
      const still = m.kind !== 'video';
      const sc = Math.max(W / iw, H / ih) * (still ? 1.07 : 1);
      const dw = iw * sc, dh = ih * sc;
      const dx = (W - dw) / 2 + (still ? (clamp(lt / dur) - 0.5) * 50 : 0), dy = (H - dh) / 2;
      const wob = 1 - easeOut(lt / 1.1);
      if (wob > 0.02) {
        // Horizontal slices, each nudged by a wave that dies down.
        for (let sy = 0; sy < H; sy += 12) {
          const off = Math.sin(sy * 0.022 + lt * 9) * 26 * wob;
          ctx.drawImage(el, 0, (sy - dy) / sc, iw, 12 / sc, dx + off, sy, dw, 12);
        }
      } else {
        ctx.drawImage(el, dx, dy, dw, dh);
      }
      drawCaustics(t, 0, 0, W, H, 0.2);
      const tg = ctx.createLinearGradient(0, 0, 0, H * 0.55);
      tg.addColorStop(0, 'rgba(2,18,30,0.9)'); tg.addColorStop(0.6, 'rgba(2,18,30,0.55)'); tg.addColorStop(1, 'rgba(2,18,30,0)');
      ctx.fillStyle = tg; ctx.fillRect(0, 0, W, H * 0.55);
      const bg = ctx.createLinearGradient(0, H * 0.7, 0, H);
      bg.addColorStop(0, 'rgba(2,18,30,0)'); bg.addColorStop(1, 'rgba(2,18,30,0.7)');
      ctx.fillStyle = bg; ctx.fillRect(0, H * 0.7, W, H * 0.3);
    }

    // The shop logo, cropped to a circle (white behind transparent logos). Returns false if there is none.
    function drawLogoCircle(cx, cy, r, ring, ringWidth) {
      const logo = getMedia(ad.brand && ad.brand.logo);
      if (!logo) return false;
      const iw = logo.el.naturalWidth || logo.el.videoWidth, ih = logo.el.naturalHeight || logo.el.videoHeight;
      const sc = Math.max((r * 2) / iw, (r * 2) / ih);
      ctx.save(); ctx.beginPath(); ctx.arc(cx, cy, r, 0, TAU); ctx.clip();
      ctx.fillStyle = '#ffffff'; ctx.fillRect(cx - r, cy - r, r * 2, r * 2);
      ctx.drawImage(logo.el, cx - (iw * sc) / 2, cy - (ih * sc) / 2, iw * sc, ih * sc);
      ctx.restore();
      ctx.beginPath(); ctx.arc(cx, cy, r, 0, TAU); ctx.strokeStyle = ring; ctx.lineWidth = ringWidth; ctx.stroke();
      return true;
    }

    // Top of every scene (just under the Reels top bar): logo + shop name, centred together.
    function drawBrandTag() {
      const name = (ad.brand && ad.brand.name) || '';
      const showLogo = !(ad.brand && ad.brand.showLogo === false) && getMedia(ad.brand && ad.brand.logo);
      if (!name && !showLogo) return;
      const text = name.toUpperCase().split('').join(String.fromCharCode(8202));
      ctx.save();
      ctx.font = `800 36px ${FONT}`;
      const r = 42, gap = showLogo && name ? 20 : 0;
      const tw = name ? Math.min(ctx.measureText(text).width, W - 300) : 0;
      let x = (W - ((showLogo ? r * 2 : 0) + gap + tw)) / 2;
      const cy = 290;
      ctx.shadowColor = 'rgba(0,0,0,0.45)'; ctx.shadowBlur = 14;
      if (showLogo) { drawLogoCircle(x + r, cy, r, 'rgba(255,255,255,0.9)', 4); x += r * 2 + gap; }
      if (name) {
        ctx.textAlign = 'left'; ctx.textBaseline = 'middle'; ctx.fillStyle = 'rgba(255,255,255,0.95)';
        ctx.fillText(text, x, cy + 2, tw);
      }
      ctx.restore();
    }

    // Letters float up one by one like bubbles, wobbling until they settle. Caller sets font/colour.
    function drawRisingText(lines, lt, y, lineH, delay) {
      const count = Math.max(1, lines.join('').length);
      const step = Math.min(0.035, 0.7 / count);
      let idx = 0;
      ctx.textAlign = 'left';
      for (const line of lines) {
        const x0 = W / 2 - ctx.measureText(line).width / 2;
        for (let j = 0; j < line.length; j++, idx++) {
          if (line[j] === ' ') continue;
          const d = lt - delay - idx * step;
          const e = easeOut(d / 0.55);
          if (e <= 0) continue;
          const pre = ctx.measureText(line.slice(0, j)).width;
          ctx.save(); ctx.globalAlpha *= e;
          ctx.fillText(line[j], x0 + pre + Math.sin(d * 13 + j) * 9 * (1 - e), y + (1 - e) * 80);
          ctx.restore();
        }
        y += lineH;
      }
      return y;
    }

    // Sub-text arrives rippling, as if read through moving water, then settles. Rendered once to a
    // small canvas (cached) and drawn in slices.
    const subCache = new Map();
    function subCanvas(lines) {
      const key = lines.join('\n') + (document.fonts && document.fonts.check(`600 52px Montserrat`) ? '|m' : '');
      if (subCache.has(key)) return subCache.get(key);
      if (subCache.size > 40) subCache.clear();
      const c = document.createElement('canvas');
      c.width = W; c.height = lines.length * 66 + 30;
      const x = c.getContext('2d');
      x.font = `600 52px ${FONT}`; x.textAlign = 'center'; x.textBaseline = 'top';
      x.fillStyle = '#bdeff5'; x.shadowColor = 'rgba(0,0,0,0.5)'; x.shadowBlur = 14;
      lines.forEach((l, i) => x.fillText(l, W / 2, 10 + i * 66));
      subCache.set(key, c);
      return c;
    }
    function drawRippledSub(lines, lt, y) {
      const e = easeOut((lt - 0.4) / 0.8);
      if (e <= 0) return;
      const c = subCanvas(lines);
      const amp = 16 * (1 - e);
      ctx.save(); ctx.globalAlpha *= e;
      for (let sy = 0; sy < c.height; sy += 3) {
        ctx.drawImage(c, 0, sy, W, 3, Math.sin(sy * 0.06 + lt * 8) * amp, y - 10 + sy, W, 3);
      }
      ctx.restore();
    }

    // Headline + sub-text from y=420 (below the Reels top bar). Returns the y under the text.
    function drawText(s, lt) {
      let y = 420;
      ctx.save();
      ctx.textBaseline = 'top';
      ctx.shadowColor = 'rgba(0,0,0,0.45)'; ctx.shadowBlur = 18; ctx.shadowOffsetY = 4;
      ctx.font = `800 104px ${FONT}`; ctx.fillStyle = '#ffffff';
      y = drawRisingText(wrap(s.headline, 940), lt, y, 116, 0);
      ctx.restore();
      if (s.sub) {
        ctx.save(); ctx.font = `600 52px ${FONT}`;
        const lines = wrap(s.sub, 920);
        ctx.restore();
        y += 14;
        drawRippledSub(lines, lt, y);
        y += lines.length * 66;
      }
      return y;
    }

    // Checklist as glass tiles: each rises in, a glint runs across it, and its tick draws itself.
    function drawBullets(list, lt, y) {
      (list || []).filter(Boolean).forEach((text, i) => {
        const d = lt - 0.7 - i * 0.28;
        const b = easeOut(d / 0.5);
        if (b > 0) {
          ctx.save(); ctx.globalAlpha *= b;
          ctx.font = `600 50px ${FONT}`;
          const tw = Math.min(ctx.measureText(text).width, W - 230), bw = tw + 150, bx = (W - bw) / 2, by = y + (1 - b) * 40;
          roundRect(bx, by, bw, 96, 20); ctx.fillStyle = 'rgba(2,22,37,0.62)'; ctx.fill();
          ctx.strokeStyle = 'rgba(205,250,255,0.6)'; ctx.lineWidth = 2.5; ctx.stroke();
          ctx.save();
          roundRect(bx, by, bw, 96, 20); ctx.clip();
          ctx.fillStyle = 'rgba(255,255,255,0.08)'; ctx.fillRect(bx, by, bw, 30); // glass top edge
          const g = clamp((d - 0.1) / 0.7);
          if (g > 0 && g < 1) {
            const gx = bx - 120 + g * (bw + 240);
            const glint = ctx.createLinearGradient(gx - 60, 0, gx + 60, 0);
            glint.addColorStop(0, 'rgba(255,255,255,0)'); glint.addColorStop(0.5, 'rgba(255,255,255,0.35)'); glint.addColorStop(1, 'rgba(255,255,255,0)');
            ctx.fillStyle = glint; ctx.setTransform(ctx.getTransform().translate(gx, by).skewX(-25).translate(-gx, -by));
            ctx.fillRect(gx - 60, by, 120, 96);
          }
          ctx.restore();
          roundRect(bx + 28, by + 22, 52, 52, 12);
          ctx.fillStyle = withAlpha(ad.accent, 0.18); ctx.fill();
          ctx.strokeStyle = ad.accent; ctx.lineWidth = 4; ctx.stroke();
          // Tick drawn as it is "written": first stroke, then the long one.
          const p = clamp((d - 0.25) / 0.35);
          if (p > 0) {
            const A = [bx + 41, by + 49], B = [bx + 51, by + 59], C = [bx + 68, by + 37];
            const ab = Math.hypot(B[0] - A[0], B[1] - A[1]), bc = Math.hypot(C[0] - B[0], C[1] - B[1]);
            const len = p * (ab + bc);
            ctx.beginPath(); ctx.moveTo(A[0], A[1]);
            if (len <= ab) ctx.lineTo(A[0] + (B[0] - A[0]) * len / ab, A[1] + (B[1] - A[1]) * len / ab);
            else { ctx.lineTo(B[0], B[1]); const f = (len - ab) / bc; ctx.lineTo(B[0] + (C[0] - B[0]) * f, B[1] + (C[1] - B[1]) * f); }
            ctx.strokeStyle = '#ffffff'; ctx.lineWidth = 6; ctx.lineCap = 'round'; ctx.lineJoin = 'round'; ctx.stroke();
          }
          ctx.fillStyle = '#fff'; ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
          ctx.fillText(text, bx + 100, by + 50, tw);
          ctx.restore();
        }
        y += 122;
      });
      return y;
    }

    function drawCta(s, lt, t) {
      const a = easeOut(lt / 0.6);
      ctx.save(); ctx.globalAlpha *= a;
      drawRipples(W / 2, 470, 120, t, a);
      drawLogoCircle(W / 2, 470, 120, ad.accent, 6);
      ctx.textAlign = 'center'; ctx.textBaseline = 'top'; ctx.fillStyle = '#fff';
      ctx.font = `800 64px ${FONT}`; ctx.fillText((ad.brand && ad.brand.name) || '', W / 2, 625, 980);
      ctx.restore();
      ctx.save();
      ctx.textBaseline = 'top'; ctx.font = `800 96px ${FONT}`; ctx.fillStyle = '#fff';
      ctx.shadowColor = 'rgba(0,0,0,0.45)'; ctx.shadowBlur = 18;
      let y = drawRisingText(wrap(s.headline, 940), lt, 760, 108, 0.2);
      ctx.restore();
      y += 30;
      if (s.button) {
        // The button fills with water in the accent colour; the text turns dark where the water is.
        const b = easeOut((lt - 0.5) / 0.5);
        const fill = easeInOut((lt - 0.8) / 1.1);
        ctx.save(); ctx.globalAlpha *= b;
        ctx.font = `800 64px ${FONT}`;
        const bw = Math.min(ctx.measureText(s.button).width, 860) + 120, bh = 140, bx = (W - bw) / 2, by = y;
        roundRect(bx, by, bw, bh, 70); ctx.fillStyle = 'rgba(2,22,37,0.55)'; ctx.fill();
        ctx.save(); ctx.shadowColor = withAlpha(ad.accent, 0.6); ctx.shadowBlur = 30 * fill;
        ctx.strokeStyle = ad.accent; ctx.lineWidth = 5; ctx.stroke(); ctx.restore();
        const level = by + bh - fill * (bh + 20);
        const waterPath = () => {
          ctx.beginPath(); ctx.moveTo(bx, by + bh);
          for (let x = bx; x <= bx + bw; x += 12) ctx.lineTo(x, level + Math.sin(x * 0.045 + t * 6) * 7);
          ctx.lineTo(bx + bw, by + bh); ctx.closePath();
        };
        ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
        ctx.fillStyle = '#ffffff'; ctx.fillText(s.button, W / 2, by + bh / 2 + 4, 860);
        ctx.save();
        roundRect(bx, by, bw, bh, 70); ctx.clip();
        waterPath(); ctx.fillStyle = ad.accent; ctx.fill();
        waterPath(); ctx.clip();
        ctx.fillStyle = textOn(ad.accent); ctx.fillText(s.button, W / 2, by + bh / 2 + 4, 860);
        for (let k = 0; k < 7; k++) {
          const bubX = bx + 70 + rand(k + 400) * (bw - 140);
          const bubY = by + bh - ((t * 55 + rand(k + 410) * bh) % bh);
          ctx.beginPath(); ctx.arc(bubX, bubY, 3 + rand(k + 420) * 3, 0, TAU);
          ctx.strokeStyle = 'rgba(255,255,255,0.55)'; ctx.lineWidth = 2; ctx.stroke();
        }
        ctx.restore();
        ctx.restore();
        y += 180;
      }
      (s.bullets || []).filter(Boolean).forEach((line, i) => {
        const b = easeOut((lt - 0.8 - i * 0.2) / 0.5);
        ctx.save(); ctx.globalAlpha *= b; ctx.textAlign = 'center'; ctx.textBaseline = 'top';
        ctx.font = `600 48px ${FONT}`; ctx.fillStyle = '#bdeff5'; ctx.fillText(line, W / 2, y, 980); ctx.restore();
        y += 64;
      });
      if (s.footer) {
        const b = easeOut((lt - 1.3) / 0.5);
        ctx.save(); ctx.globalAlpha *= b; ctx.textAlign = 'center'; ctx.textBaseline = 'top';
        ctx.font = `800 44px ${FONT}`; ctx.fillStyle = '#ffd166'; ctx.fillText(s.footer, W / 2, y + 24, 980); ctx.restore();
      }
    }

    // Logo scene: the shop logo big in the centre, revealed by water rising up through it, with
    // ripple rings spreading out and the tank's caustic light playing across it. Without a logo,
    // the shop name sits in the ring instead.
    function drawLogoHero(lt, t, cy) {
      const r = 250, cx = W / 2;
      const a = clamp(lt / 0.3);
      if (a <= 0) return;
      cy += Math.sin(t * 1.1) * 8;
      ctx.save();
      ctx.globalAlpha *= a;
      const glowR = r * 1.6;
      const glow = ctx.createRadialGradient(cx, cy, r * 0.7, cx, cy, glowR);
      glow.addColorStop(0, withAlpha(ad.accent, 0.4)); glow.addColorStop(1, withAlpha(ad.accent, 0));
      ctx.fillStyle = glow; ctx.beginPath(); ctx.arc(cx, cy, glowR, 0, TAU); ctx.fill();
      drawRipples(cx, cy, r, t, clamp((lt - 0.7) / 0.5));
      // Faint empty ring first, then the logo fills in from the bottom.
      ctx.beginPath(); ctx.arc(cx, cy, r, 0, TAU);
      ctx.strokeStyle = withAlpha(ad.accent, 0.5); ctx.lineWidth = 6; ctx.stroke();
      const q = easeInOut((lt - 0.05) / 1.0);
      const lineAt = (x) => cy + r + 20 - q * (2 * r + 60) + Math.sin(x * 0.035 + t * 7) * 12 * (1 - q * 0.6);
      ctx.save();
      ctx.beginPath(); ctx.moveTo(cx - r - 20, cy + r + 40);
      for (let x = cx - r - 20; x <= cx + r + 20; x += 10) ctx.lineTo(x, lineAt(x));
      ctx.lineTo(cx + r + 20, cy + r + 40); ctx.closePath(); ctx.clip();
      if (!drawLogoCircle(cx, cy, r, ad.accent, 12)) {
        ctx.beginPath(); ctx.arc(cx, cy, r, 0, TAU); ctx.fillStyle = 'rgba(2,22,37,0.85)'; ctx.fill();
        ctx.strokeStyle = ad.accent; ctx.lineWidth = 12; ctx.stroke();
        ctx.fillStyle = '#fff'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
        ctx.font = `800 ${Math.round(r * 0.28)}px ${FONT}`;
        wrap((ad.brand && ad.brand.name) || '', r * 1.6).slice(0, 3).forEach((line, i, all) => {
          ctx.fillText(line, cx, cy + (i - (all.length - 1) / 2) * r * 0.32, r * 1.7);
        });
      }
      ctx.beginPath(); ctx.arc(cx, cy, r, 0, TAU); ctx.clip();
      drawCaustics(t, cx - r, cy - r * 1.8, r * 2, r * 3.6, 0.32);
      ctx.restore();
      if (q > 0 && q < 1) {
        ctx.save();
        ctx.beginPath(); ctx.arc(cx, cy, r, 0, TAU); ctx.clip();
        ctx.beginPath();
        for (let x = cx - r; x <= cx + r; x += 10) ctx[x === cx - r ? 'moveTo' : 'lineTo'](x, lineAt(x));
        ctx.shadowColor = 'rgba(200,250,255,0.9)'; ctx.shadowBlur = 14;
        ctx.strokeStyle = 'rgba(240,253,255,0.95)'; ctx.lineWidth = 5; ctx.stroke();
        ctx.restore();
      }
      ctx.restore();
    }

    // ---------- payments: each method is a card that drops into the water, splashes and bobs ----------
    function drawPayCard(key, w, h) {
      const x = -w / 2, y = -h / 2, r = h * 0.1;
      const fills = { visa: ['#1a1f71', '#2a3a9e'], mastercard: ['#16181d', '#2c3038'], gcash: ['#0062e0', '#1f8bff'],
        maya: ['#0b0b0b', '#1d1d1d'], qrph: ['#ffffff', '#e9eef3'], bank: ['#0d3b66', '#1a5a91'], cash: ['#1f7a3a', '#2fa152'] };
      const [c1, c2] = fills[key] || fills.bank;
      const bg = ctx.createLinearGradient(x, y, x + w, y + h);
      bg.addColorStop(0, c1); bg.addColorStop(1, c2);
      roundRect(x, y, w, h, r); ctx.fillStyle = bg; ctx.fill();
      ctx.strokeStyle = 'rgba(255,255,255,0.35)'; ctx.lineWidth = 2; ctx.stroke();
      ctx.save(); roundRect(x, y, w, h, r); ctx.clip();
      ctx.textBaseline = 'middle'; ctx.textAlign = 'center';
      const chip = () => {
        roundRect(x + w * 0.1, y + h * 0.3, w * 0.16, h * 0.24, 6); ctx.fillStyle = '#d9b45a'; ctx.fill();
        ctx.strokeStyle = 'rgba(0,0,0,0.25)'; ctx.lineWidth = 1.5; ctx.stroke();
      };
      if (key === 'visa') {
        chip();
        ctx.font = `italic 900 ${h * 0.3}px ${FONT}`; ctx.fillStyle = '#ffffff'; ctx.fillText('VISA', x + w * 0.66, y + h * 0.66);
        ctx.fillStyle = '#f7b600'; ctx.fillRect(x, y + h * 0.88, w, h * 0.06);
      } else if (key === 'mastercard') {
        chip();
        const cy = y + h * 0.56, rr = h * 0.2;
        ctx.beginPath(); ctx.arc(x + w * 0.62, cy, rr, 0, TAU); ctx.fillStyle = '#eb001b'; ctx.fill();
        ctx.beginPath(); ctx.arc(x + w * 0.62 + rr * 1.2, cy, rr, 0, TAU); ctx.fillStyle = 'rgba(247,158,27,0.92)'; ctx.fill();
        ctx.font = `700 ${h * 0.11}px ${FONT}`; ctx.fillStyle = '#ffffff'; ctx.fillText('mastercard', x + w * 0.72, y + h * 0.86);
      } else if (key === 'gcash') {
        ctx.font = `900 ${h * 0.3}px ${FONT}`; ctx.fillStyle = '#ffffff'; ctx.fillText('GCash', x + w / 2, y + h * 0.52);
      } else if (key === 'maya') {
        ctx.font = `900 ${h * 0.32}px ${FONT}`; ctx.fillStyle = '#00d26a'; ctx.fillText('maya', x + w / 2, y + h * 0.5);
      } else if (key === 'qrph') {
        const q = h * 0.62, qx = x + w * 0.1, qy = y + (h - q) / 2, n = 9, cell = q / n;
        ctx.fillStyle = '#0b1b2b';
        for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) {
          const finder = (i < 3 && j < 3) || (i > 5 && j < 3) || (i < 3 && j > 5);
          if (finder ? !(i % 6 === 1 && j % 6 === 1) : rand(i * 13 + j * 7) > 0.5) ctx.fillRect(qx + i * cell, qy + j * cell, cell, cell);
        }
        ctx.font = `900 ${h * 0.24}px ${FONT}`; ctx.fillStyle = '#c8102e'; ctx.fillText('QR Ph', x + w * 0.7, y + h * 0.52);
      } else if (key === 'bank') {
        const bx = x + w * 0.22, by = y + h * 0.5, s = h * 0.36;
        ctx.fillStyle = '#ffffff';
        ctx.beginPath(); ctx.moveTo(bx - s * 0.6, by - s * 0.2); ctx.lineTo(bx, by - s * 0.6); ctx.lineTo(bx + s * 0.6, by - s * 0.2); ctx.closePath(); ctx.fill();
        for (let i = 0; i < 4; i++) ctx.fillRect(bx - s * 0.5 + i * s * 0.3, by - s * 0.12, s * 0.12, s * 0.5);
        ctx.fillRect(bx - s * 0.6, by + s * 0.42, s * 1.2, s * 0.12);
        ctx.font = `800 ${h * 0.15}px ${FONT}`; ctx.fillText('Bank', x + w * 0.65, y + h * 0.4); ctx.fillText('transfer', x + w * 0.65, y + h * 0.6);
      } else if (key === 'cash') {
        ctx.beginPath(); ctx.arc(x + w * 0.25, y + h * 0.5, h * 0.26, 0, TAU); ctx.strokeStyle = 'rgba(255,255,255,0.8)'; ctx.lineWidth = 4; ctx.stroke();
        ctx.font = `900 ${h * 0.3}px ${FONT}`; ctx.fillStyle = '#ffffff'; ctx.fillText('₱', x + w * 0.25, y + h * 0.52);
        ctx.font = `800 ${h * 0.24}px ${FONT}`; ctx.fillText('Cash', x + w * 0.66, y + h * 0.52);
      }
      ctx.restore();
    }

    function drawPayments(s, lt, top, maxH) {
      const keys = PAY_METHODS.map(([k]) => k).filter((k) => !Array.isArray(s.methods) || !s.methods.length || s.methods.includes(k));
      if (!keys.length) return;
      const cols = keys.length <= 4 ? 2 : 3, rows = Math.ceil(keys.length / cols), gap = 26;
      const ch = Math.min(200, (maxH - gap * (rows - 1)) / rows, ((W - 120 - gap * (cols - 1)) / cols) / 1.58);
      const cw = ch * 1.58;
      keys.forEach((key, i) => {
        const row = Math.floor(i / cols), inRow = Math.min(cols, keys.length - row * cols), col = i % cols;
        const cx = W / 2 + (col - (inRow - 1) / 2) * (cw + gap);
        const cy = top + ch / 2 + row * (ch + gap);
        const land = 0.35 + i * 0.16;
        const k = clamp((lt - land) / 0.45);
        if (k <= 0) return;
        // Falls in, overshoots under the "surface" and floats back up, then bobs.
        const drop = k < 1 ? -380 * Math.pow(1 - k, 2) + Math.sin(k * Math.PI) * 30 : 0;
        const bob = Math.sin(lt * 2.1 + i * 1.3) * 6 * clamp((lt - land - 0.45) / 0.4);
        const tilt = (i % 2 ? 1 : -1) * (0.2 * (1 - easeOut(k)) + 0.035);
        if (k > 0.55) drawRipples(cx, cy + ch * 0.1, ch * 0.32, lt - land, clamp(1.6 - (lt - land)) * 0.8);
        ctx.save();
        ctx.globalAlpha *= clamp(k * 2.5);
        ctx.translate(cx, cy + drop + bob); ctx.rotate(tilt);
        ctx.shadowColor = 'rgba(0,0,0,0.35)'; ctx.shadowBlur = 24; ctx.shadowOffsetY = 12;
        roundRect(-cw / 2, -ch / 2, cw, ch, ch * 0.1); ctx.fillStyle = '#000'; ctx.fill();
        ctx.shadowColor = 'transparent';
        drawPayCard(key, cw, ch);
        // One glint across each card after it settles.
        const g = (lt - land - 0.45) / 0.6;
        if (g > 0 && g < 1) {
          ctx.save(); roundRect(-cw / 2, -ch / 2, cw, ch, ch * 0.1); ctx.clip();
          ctx.transform(1, 0, -0.45, 1, 0, 0);
          const gx = -cw + g * cw * 2.4;
          const sh = ctx.createLinearGradient(gx - 50, 0, gx + 50, 0);
          sh.addColorStop(0, 'rgba(255,255,255,0)'); sh.addColorStop(0.5, 'rgba(255,255,255,0.45)'); sh.addColorStop(1, 'rgba(255,255,255,0)');
          ctx.fillStyle = sh; ctx.fillRect(gx - 50, -ch, 100, ch * 2);
          ctx.restore();
        }
        ctx.restore();
      });
    }

    // ---------- delivery: our truck rolls up to a house, the wrapped aquarium floats to the door ----------
    function drawDelivery(s, lt, top, maxH) {
      const sc = clamp(maxH / 560, 0.6, 1.1);
      const gy = top + maxH * 0.78;           // where the wheels touch the road
      // Road with its centre line sliding by while the truck is moving.
      const drive = easeOut((lt - 0.1) / 1.4);
      const moving = drive < 1;
      ctx.fillStyle = 'rgba(8,24,36,0.75)'; ctx.fillRect(0, gy, W, 70 * sc);
      ctx.fillStyle = 'rgba(255,255,255,0.18)'; ctx.fillRect(0, gy, W, 3);
      ctx.fillStyle = 'rgba(255,209,102,0.85)';
      const dashOff = -drive * 900;
      for (let x = (dashOff % 120) - 120; x < W; x += 120) ctx.fillRect(x, gy + 33 * sc, 60, 6 * sc);

      // House on the right, lights on.
      const hw = 250 * sc, hh = 190 * sc, hx = W - 70 - hw, hy = gy - hh;
      const houseIn = easeOut((lt - 0.1) / 0.6);
      ctx.save(); ctx.globalAlpha *= houseIn;
      ctx.fillStyle = '#e8eef2'; ctx.fillRect(hx, hy, hw, hh);
      ctx.fillStyle = '#c0502e';
      ctx.beginPath(); ctx.moveTo(hx - 24 * sc, hy + 4); ctx.lineTo(hx + hw / 2, hy - 120 * sc); ctx.lineTo(hx + hw + 24 * sc, hy + 4); ctx.closePath(); ctx.fill();
      const doorX = hx + hw * 0.18, doorW = hw * 0.26, doorH = hh * 0.62;
      ctx.fillStyle = '#7a4a2a'; ctx.fillRect(doorX, gy - doorH, doorW, doorH);
      ctx.fillStyle = '#ffd166'; ctx.beginPath(); ctx.arc(doorX + doorW * 0.8, gy - doorH * 0.45, 4 * sc, 0, TAU); ctx.fill();
      ctx.fillStyle = 'rgba(255,214,120,0.95)'; ctx.fillRect(hx + hw * 0.56, hy + hh * 0.22, hw * 0.3, hh * 0.3);
      ctx.strokeStyle = '#7a8a96'; ctx.lineWidth = 3; ctx.strokeRect(hx + hw * 0.56, hy + hh * 0.22, hw * 0.3, hh * 0.3);
      ctx.restore();

      // The truck: box body in the accent colour with our logo and name, cab at the front (right).
      const tw = 470 * sc, th = 210 * sc;
      const stopX = hx - 40 * sc - tw;
      const tx = -tw - 40 + (stopX + tw + 40) * drive;
      const bounce = moving ? Math.sin(lt * 26) * 2 : 0;
      const ty = gy - th - 34 * sc + bounce;
      const boxW = tw * 0.7, cabW = tw - boxW - 6 * sc;
      ctx.save();
      // Bubbles from the exhaust while it drives (we're underwater, after all).
      if (lt > 0.2) {
        for (let i = 0; i < 10; i++) {
          const age = ((lt * 1.4 + i / 10) % 1);
          const bx = tx - 10 - age * 140 * (moving ? 1 : 0.3), by = gy - 26 * sc - age * 130 + Math.sin(age * 9 + i) * 8;
          ctx.beginPath(); ctx.arc(bx, by, (3 + age * 7) * sc, 0, TAU);
          ctx.strokeStyle = `rgba(220,250,255,${0.7 * (1 - age)})`; ctx.lineWidth = 2; ctx.stroke();
        }
      }
      roundRect(tx, ty, boxW, th, 10 * sc); ctx.fillStyle = '#f4f7f9'; ctx.fill();
      ctx.fillStyle = ad.accent; ctx.fillRect(tx, ty + th * 0.68, boxW, th * 0.14);
      const logoR = th * 0.2;
      const hasLogo = drawLogoCircle(tx + logoR + 22 * sc, ty + th * 0.36, logoR, ad.accent, 4);
      ctx.font = `900 ${Math.round(th * 0.15)}px ${FONT}`; ctx.textAlign = 'left'; ctx.textBaseline = 'middle'; ctx.fillStyle = '#0b2233';
      const name = String((ad.brand && ad.brand.name) || 'RS Pet Stop').toUpperCase();
      const nameX = tx + (hasLogo ? logoR * 2 + 40 * sc : 24 * sc);
      ctx.fillText(name, nameX, ty + th * 0.3, boxW - (nameX - tx) - 14 * sc);
      ctx.font = `700 ${Math.round(th * 0.09)}px ${FONT}`; ctx.fillStyle = '#3a5566';
      ctx.fillText('Delivery team', nameX, ty + th * 0.48);
      // Cab
      const cx0 = tx + boxW + 6 * sc, cy0 = ty + th * 0.25;
      ctx.fillStyle = '#2b333a';
      ctx.beginPath(); ctx.moveTo(cx0, cy0); ctx.lineTo(cx0 + cabW * 0.6, cy0); ctx.lineTo(cx0 + cabW, cy0 + th * 0.32); ctx.lineTo(cx0 + cabW, ty + th); ctx.lineTo(cx0, ty + th); ctx.closePath(); ctx.fill();
      ctx.fillStyle = 'rgba(160,220,240,0.85)';
      ctx.beginPath(); ctx.moveTo(cx0 + cabW * 0.12, cy0 + 10 * sc); ctx.lineTo(cx0 + cabW * 0.56, cy0 + 10 * sc); ctx.lineTo(cx0 + cabW * 0.86, cy0 + th * 0.3); ctx.lineTo(cx0 + cabW * 0.12, cy0 + th * 0.3); ctx.closePath(); ctx.fill();
      ctx.fillStyle = '#ffd166'; ctx.fillRect(cx0 + cabW - 10 * sc, ty + th * 0.72, 10 * sc, 14 * sc);
      ctx.fillStyle = '#1b2026'; ctx.fillRect(tx, ty + th - 4, tw, 10 * sc);
      // Wheels (spinning while it drives)
      for (const wx of [tx + boxW * 0.22, tx + boxW * 0.62, cx0 + cabW * 0.55]) {
        const wr = 30 * sc, wy = gy - wr;
        ctx.beginPath(); ctx.arc(wx, wy, wr, 0, TAU); ctx.fillStyle = '#111418'; ctx.fill();
        ctx.beginPath(); ctx.arc(wx, wy, wr * 0.48, 0, TAU); ctx.fillStyle = '#9aa5ad'; ctx.fill();
        const a = drive * 18;
        ctx.strokeStyle = '#5d676f'; ctx.lineWidth = 3;
        for (let k = 0; k < 3; k++) {
          const ang = a + (k * TAU) / 3;
          ctx.beginPath(); ctx.moveTo(wx, wy); ctx.lineTo(wx + Math.cos(ang) * wr * 0.46, wy + Math.sin(ang) * wr * 0.46); ctx.stroke();
        }
      }
      ctx.restore();

      // Once parked, the wrapped aquarium floats from the truck to the front door.
      const f = easeInOut((lt - 1.55) / 0.85);
      if (f > 0) {
        const bw = 120 * sc, bh = 86 * sc;
        const sx = tx + boxW * 0.55, sy = ty + th * 0.4;
        const ex = doorX + doorW / 2 - 20 * sc, ey = gy - bh / 2 - 6;
        const px = sx + (ex - sx) * f, py = sy + (ey - sy) * f - Math.sin(f * Math.PI) * 120 * sc;
        ctx.save();
        ctx.translate(px, py); ctx.rotate(Math.sin(f * Math.PI) * 0.08);
        ctx.fillStyle = '#c9a26b'; ctx.fillRect(-bw / 2, -bh / 2, bw, bh);
        ctx.strokeStyle = '#8a6a3c'; ctx.lineWidth = 3; ctx.strokeRect(-bw / 2, -bh / 2, bw, bh);
        ctx.fillStyle = 'rgba(255,255,255,0.75)'; ctx.fillRect(-bw / 2, -6 * sc, bw, 12 * sc);
        ctx.fillStyle = '#c0392b'; ctx.font = `900 ${Math.round(bh * 0.2)}px ${FONT}`; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
        ctx.fillText('FRAGILE', 0, -bh * 0.27);
        ctx.strokeStyle = '#c0392b'; ctx.lineWidth = 3;
        ctx.beginPath(); ctx.moveTo(-10 * sc, bh * 0.16); ctx.lineTo(-7 * sc, bh * 0.4); ctx.lineTo(7 * sc, bh * 0.4); ctx.lineTo(10 * sc, bh * 0.16); ctx.closePath(); ctx.stroke();
        ctx.restore();
      }
      // Delivered: a tick badge pops over the door.
      const d = easeOut((lt - 2.45) / 0.35);
      if (d > 0) {
        const bx = doorX + doorW / 2, by = hy - 150 * sc, r = 44 * sc * (0.6 + 0.4 * d);
        drawRipples(bx, by, r, lt - 2.45, clamp(2 - (lt - 2.45)) * 0.9);
        ctx.save(); ctx.globalAlpha *= clamp(d * 1.5);
        ctx.beginPath(); ctx.arc(bx, by, r, 0, TAU); ctx.fillStyle = '#22c55e'; ctx.fill();
        ctx.strokeStyle = '#ffffff'; ctx.lineWidth = 7 * sc; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
        ctx.beginPath(); ctx.moveTo(bx - r * 0.42, by + r * 0.02); ctx.lineTo(bx - r * 0.1, by + r * 0.34); ctx.lineTo(bx + r * 0.45, by - r * 0.3); ctx.stroke();
        ctx.restore();
      }
    }

    // ---------- reviews: five stars pop, then each quote rises up like an air bubble and settles ----------
    function drawStar(cx, cy, r, fill) {
      ctx.beginPath();
      for (let i = 0; i < 10; i++) {
        const a = -Math.PI / 2 + (i * Math.PI) / 5, rr = i % 2 ? r * 0.45 : r;
        ctx.lineTo(cx + Math.cos(a) * rr, cy + Math.sin(a) * rr);
      }
      ctx.closePath(); ctx.fillStyle = fill; ctx.fill();
    }

    function drawReviews(s, lt, top, maxH) {
      // Stars
      const sr = 46, sgap = 112;
      for (let i = 0; i < 5; i++) {
        const k = clamp((lt - 0.05 - i * 0.1) / 0.3);
        if (k <= 0) continue;
        const pop = k < 1 ? 1 + Math.sin(k * Math.PI) * 0.35 : 1;
        const cx = W / 2 + (i - 2) * sgap, cy = top + sr;
        ctx.save(); ctx.globalAlpha *= clamp(k * 2);
        ctx.shadowColor = 'rgba(255,209,102,0.7)'; ctx.shadowBlur = 24;
        drawStar(cx, cy, sr * pop * easeOut(k), '#ffd166');
        ctx.restore();
      }
      const lk = easeOut((lt - 0.55) / 0.4);
      if (lk > 0) {
        ctx.save(); ctx.globalAlpha *= lk;
        ctx.font = `700 34px ${FONT}`; ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.fillStyle = '#cfefff';
        ctx.fillText('Real reviews from our Facebook page', W / 2, top + sr * 2 + 34);
        ctx.restore();
      }

      // Quote bubbles, stacked under the stars.
      const list = (Array.isArray(s.reviews) ? s.reviews : []).filter((r) => r && String(r.text || '').trim()).slice(0, 3);
      if (!list.length) return;
      const bw = 900, padX = 44, padY = 30;
      const fs = list.length > 2 ? 36 : 40, lineH = Math.round(fs * 1.28);
      let y = top + sr * 2 + 84;
      const room = top + maxH - y;
      ctx.save(); ctx.font = `600 ${fs}px ${FONT}`;
      const bubbles = list.map((r) => {
        let lines = wrap('“' + String(r.text).trim() + '”', bw - padX * 2);
        if (lines.length > 4) { lines = lines.slice(0, 4); lines[3] = lines[3].replace(/\s*\S*$/, '') + '…”'; }
        return { lines, name: String(r.name || '').trim(), h: padY * 2 + lines.length * lineH + 48 };
      });
      ctx.restore();
      const total = bubbles.reduce((a, b) => a + b.h, 0) + 28 * (bubbles.length - 1);
      const scale = Math.min(1, room / total);
      bubbles.forEach((b, i) => {
        const k = clamp((lt - 0.7 - i * 0.45) / 0.7);
        const h = b.h * scale, w = bw * scale;
        if (k > 0) {
          // Rises from below with a side-to-side wobble, like an air bubble, then settles.
          const rise = (1 - easeOut(k)) * 420;
          const wob = Math.sin(lt * 5 + i) * 18 * (1 - k);
          const bob = Math.sin(lt * 1.7 + i * 2) * 4 * k;
          const x = (W - w) / 2 + wob, by = y + rise + bob;
          ctx.save(); ctx.globalAlpha *= clamp(k * 2);
          ctx.translate(x, by); ctx.scale(scale, scale);
          ctx.shadowColor = 'rgba(0,0,0,0.3)'; ctx.shadowBlur = 26; ctx.shadowOffsetY = 10;
          roundRect(0, 0, bw, b.h, 36); ctx.fillStyle = 'rgba(255,255,255,0.96)'; ctx.fill();
          ctx.shadowColor = 'transparent';
          // Tail on the left, like a chat bubble.
          ctx.beginPath(); ctx.moveTo(70, b.h - 2); ctx.lineTo(54, b.h + 30); ctx.lineTo(112, b.h - 2); ctx.closePath(); ctx.fill();
          // Bubble highlight
          ctx.beginPath(); ctx.ellipse(bw - 90, 34, 46, 12, -0.15, 0, TAU); ctx.fillStyle = 'rgba(190,235,255,0.6)'; ctx.fill();
          ctx.font = `600 ${fs}px ${FONT}`; ctx.fillStyle = '#10283a'; ctx.textAlign = 'left'; ctx.textBaseline = 'top';
          b.lines.forEach((line, j) => ctx.fillText(line, padX, padY + j * lineH));
          const fy = padY + b.lines.length * lineH + 10;
          for (let j = 0; j < 5; j++) drawStar(padX + 14 + j * 30, fy + 16, 13, '#f5b400');
          ctx.font = `700 28px ${FONT}`; ctx.fillStyle = '#4a6375';
          ctx.fillText((b.name ? b.name + ' · ' : '') + 'Facebook review', padX + 170, fy + 2);
          ctx.restore();
        }
        y += (b.h + 28) * scale;
      });
    }

    function drawScene(s, lt, dur, t) {
      if (s.style === 'cta') { drawCta(s, lt, t); return; }
      const logoScene = s.style === 'logo' || s.style === 'fish'; // 'fish' = older saved ads
      const m = sceneMedia(s);
      if (m) drawMediaBg(m, lt, dur, t);
      if (!logoScene) drawBrandTag();
      const y = drawText(s, lt);
      const yb = drawBullets(s.bullets, lt, y + 40);
      if (logoScene) drawLogoHero(lt, t, Math.min(1180, Math.max(1050, yb + 330)));
      if (s.style === 'reviews') {
        const top = Math.min(900, Math.max(600, yb + 70));
        drawReviews(s, lt, top, 1460 - top);
      }
      if (s.style === 'payments' || s.style === 'delivery') {
        const top = Math.min(1000, Math.max(760, yb + 110));
        (s.style === 'payments' ? drawPayments : drawDelivery)(s, lt, top, 1440 - top);
      }
      // The tank/stand/sump sits under whatever text there is, and stops above the Reels caption area.
      const BUILDS = { tank: drawTank, stand: drawStand, sump: drawSump };
      if (BUILDS[s.style]) {
        // A tank with a cabinet / canopy is a taller stack, so it may start higher to stay a good size.
        const tall = s.style === 'tank' && s.options && (s.options.cabinet || s.options.canopy);
        const top = Math.min(1060, Math.max(tall ? 700 : 880, yb + 120));
        // Room under a tank for its option tags.
        const reserve = s.style === 'tank' && tankOptionTags(s.options).length ? 160 : 0;
        BUILDS[s.style](s, lt, top, 1420 - top - reserve);
      }
    }

    // Scenes change with the tide: the next one rises in under a waterline instead of fading.
    // The ad opens the same way, the first scene filling in over empty water.
    function drawFrame(t) {
      ctx.save();
      ctx.globalAlpha = 1;
      drawWater(t);
      if (ad && ad.scenes.length) {
        const tl = timeline();
        let i = tl.findIndex((x) => t < x.end);
        if (i < 0) i = tl.length - 1;
        const cur = tl[i];
        // A scene's own animations start once the water has risen past the middle, so the
        // headline (at the top) isn't already finished by the time it is uncovered.
        const DELAY = FADE * 0.6;
        ctx.save();
        if (i === 0 && t < FADE) {
          const q = easeInOut(t / FADE);
          tideClip(q, t);
          drawScene(cur.s, t - DELAY, cur.dur, t);
          ctx.restore();
          drawTideEdge(q, t);
        } else {
          drawScene(cur.s, t - cur.visStart - DELAY, cur.dur, t);
          ctx.restore();
        }
        const next = tl[i + 1];
        if (next && t >= next.visStart) {
          const q = easeInOut((t - next.visStart) / FADE);
          ctx.save();
          tideClip(q, t);
          drawWater(t);
          drawScene(next.s, t - next.visStart - DELAY, next.dur, t);
          ctx.restore();
          drawTideEdge(q, t);
        }
      }
      drawGlassFrame(t);
      ctx.restore();
    }

    // Live preview: keep each visible clip roughly in step with the timeline.
    function syncVideos(t, playing) {
      if (!ad) return;
      timeline().forEach((x) => {
        const m = sceneMedia(x.s);
        if (!m || m.kind !== 'video') return;
        const v = m.el, visible = t >= x.visStart && t < x.end;
        if (!visible) { if (!v.paused) v.pause(); return; }
        const target = Math.max(0, t - x.visStart) % (v.duration || 1);
        if (Math.abs(v.currentTime - target) > 0.3) v.currentTime = target;
        if (playing && v.paused) v.play().catch(() => {});
        if (!playing && !v.paused) v.pause();
      });
    }

    function pauseVideos() {
      Object.values(media).forEach((m) => { if (m.kind === 'video' && m.el && !m.el.paused) m.el.pause(); });
    }

    // Export: seek every visible clip to the exact frame time first.
    function seekVideosExact(t) {
      const waits = [];
      timeline().forEach((x) => {
        const m = sceneMedia(x.s);
        if (!m || m.kind !== 'video' || t < x.visStart || t >= x.end) return;
        const v = m.el;
        v.pause();
        const target = Math.min(Math.max(0, t - x.visStart) % v.duration, v.duration - 0.05);
        if (Math.abs(v.currentTime - target) < 0.001) return;
        waits.push(new Promise((res) => {
          const timer = setTimeout(res, 3000);
          v.addEventListener('seeked', () => { clearTimeout(timer); res(); }, { once: true });
          v.currentTime = target;
        }));
      });
      return Promise.all(waits);
    }

    async function pickCodec() {
      const base = { width: W, height: H, bitrate: 10000000, framerate: FPS };
      for (const codec of ['avc1.640033', 'avc1.640032', 'avc1.4d0033', 'avc1.42e033']) {
        for (const hardwareAcceleration of ['no-preference', 'prefer-software']) {
          const cfg = { ...base, codec, hardwareAcceleration, avc: { format: 'avc' } };
          try { if ((await VideoEncoder.isConfigSupported(cfg)).supported) return cfg; } catch (e) { /* try the next one */ }
        }
      }
      return null;
    }

    // audio: optional stereo AudioBuffer (js/videoAdMusic.js buildTrack) - muxed as AAC.
    async function pickAudioCodec(sampleRate) {
      if (!('AudioEncoder' in window)) return null;
      const cfg = { codec: 'mp4a.40.2', sampleRate, numberOfChannels: 2, bitrate: 160000 };
      try { return (await AudioEncoder.isConfigSupported(cfg)).supported ? cfg : null; } catch (e) { return null; }
    }

    // Whole soundtrack -> AAC chunks, trimmed to the video's length.
    async function encodeAudio(buffer, cfg, muxer) {
      let err = null;
      const enc = new AudioEncoder({ output: (chunk, meta) => muxer.addAudioChunk(chunk, meta), error: (e) => { err = e; } });
      enc.configure(cfg);
      const sr = buffer.sampleRate;
      const total = Math.min(buffer.length, Math.round(totalDuration() * sr));
      const left = buffer.getChannelData(0);
      const right = buffer.numberOfChannels > 1 ? buffer.getChannelData(1) : left;
      const STEP = 4800;
      for (let i = 0; i < total; i += STEP) {
        if (err) throw err;
        const n = Math.min(STEP, total - i);
        const planar = new Float32Array(n * 2);
        planar.set(left.subarray(i, i + n), 0);
        planar.set(right.subarray(i, i + n), n);
        const data = new AudioData({ format: 'f32-planar', sampleRate: sr, numberOfFrames: n, numberOfChannels: 2, timestamp: Math.round(i * 1e6 / sr), data: planar });
        enc.encode(data);
        data.close();
        while (enc.encodeQueueSize > 16) await new Promise((r) => setTimeout(r, 5));
      }
      await enc.flush();
      if (err) throw err;
      enc.close();
    }

    async function exportMp4(onProgress, audio) {
      if (!('VideoEncoder' in window) || !window.Mp4Muxer) {
        throw new Error('This browser cannot make videos. Use Chrome or Edge on a computer or Android, or Safari 16.4+ on iPhone.');
      }
      const cfg = await pickCodec();
      if (!cfg) throw new Error('This browser has no H.264 video encoder. Try Chrome or Edge.');
      const audioCfg = audio ? await pickAudioCodec(audio.sampleRate) : null;
      if (audio && !audioCfg) throw new Error('This browser cannot add music to videos. Set Music to "None", or use Chrome or Edge.');
      pauseVideos();
      await loadAll();
      const muxer = new Mp4Muxer.Muxer({
        target: new Mp4Muxer.ArrayBufferTarget(),
        video: { codec: 'avc', width: W, height: H, frameRate: FPS },
        audio: audioCfg ? { codec: 'aac', numberOfChannels: 2, sampleRate: audio.sampleRate } : undefined,
        fastStart: 'in-memory'
      });
      let encErr = null;
      if (audioCfg) await encodeAudio(audio, audioCfg, muxer);
      const enc = new VideoEncoder({ output: (chunk, meta) => muxer.addVideoChunk(chunk, meta), error: (e) => { encErr = e; } });
      enc.configure(cfg);
      const frames = Math.round(totalDuration() * FPS);
      for (let i = 0; i < frames; i++) {
        if (encErr) throw encErr;
        const t = i / FPS;
        await seekVideosExact(t);
        drawFrame(t);
        const frame = new VideoFrame(canvas, { timestamp: Math.round(i * 1e6 / FPS), duration: Math.round(1e6 / FPS) });
        enc.encode(frame, { keyFrame: i % (FPS * 2) === 0 });
        frame.close();
        while (enc.encodeQueueSize > 8) await new Promise((r) => setTimeout(r, 5));
        if (onProgress && i % 10 === 0) onProgress(i / frames);
      }
      await enc.flush();
      if (encErr) throw encErr;
      muxer.finalize();
      return new Blob([muxer.target.buffer], { type: 'video/mp4' });
    }

    return {
      setAd(next) { ad = next; return loadAll(); },
      loadMedia, loadAll, totalDuration, timeline, drawFrame, syncVideos, pauseVideos, exportMp4,
      isMediaFailed: (src) => !!(src && media[src] && media[src].failed)
    };
  }

  return { create, W, H, FPS, isVideo, TANK_OPTIONS, PAY_METHODS };
})();
