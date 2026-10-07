// "Comet night" animated background for portal pages (loaded by js/nav.js; skipped on Dashboard,
// GMA Conversations, the full-screen calculators and the print-only pages) - an anime-style evening
// sky: a deep blue-to-teal gradient, twinkling stars fading out toward the horizon, two layers of
// drifting clouds (lit tops, shadowed bellies), and a big comet crossing diagonally - glowing core,
// rainbow-edged tail, dust streaming along it, and two thin fragments splitting off below the head.
// Plus a few sparkle-flare stars and an occasional shooting star.
// One fixed <canvas class="app-sky-bg"> behind .page / #topnav (css/styles.css). Clouds are
// pre-rendered to tiling offscreen canvases (rebuilt on resize / theme change) so each frame is cheap.
// Light theme is a pale twilight version so dark page text stays readable.
// Capped at ~30 fps, paused while the tab is hidden, a still frame for "reduce motion" users.
(function () {
  if (document.querySelector('.app-sky-bg')) return;
  const canvas = document.createElement('canvas');
  canvas.className = 'app-sky-bg';
  canvas.setAttribute('aria-hidden', 'true');
  document.body.prepend(canvas);
  const ctx = canvas.getContext('2d');
  if (!ctx) return;

  const reduceMotion = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  const TAU = Math.PI * 2;
  const rand = (a, b) => a + Math.random() * (b - a);
  const smooth = (a, b, x) => {
    const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
    return t * t * (3 - 2 * t);
  };

  const PALETTES = {
    light: {
      key: 'light',
      sky: ['#c9d8f0', '#dfe7f5', '#eef1f7'],
      star: '70,85,160', warm: '190,140,40', cool: '80,110,190', flare: '90,100,180', starAlpha: 0.7,
      cloudBody: '150,168,205', cloudHi: '255,255,255', cloudAlpha: [0.35, 0.5],
      mode: 'source-over', cometAlpha: 0.8,
      comet: { glow: '90,140,230', purple: '125,80,205', magenta: '205,85,175', green: '40,165,130', cyan: '45,140,235', core: '255,255,255', head: '120,170,255' },
      meteor: '90,100,180'
    },
    dark: {
      key: 'dark',
      sky: ['#040816', '#0c2148', '#2b5b86'],
      star: '255,255,255', warm: '255,214,150', cool: '170,200,255', flare: '220,230,255', starAlpha: 1,
      cloudBody: '30,48,82', cloudHi: '125,155,198', cloudAlpha: [0.55, 0.85],
      mode: 'lighter', cometAlpha: 1,
      comet: { glow: '70,130,255', purple: '150,90,240', magenta: '235,110,210', green: '110,235,185', cyan: '90,200,255', core: '235,245,255', head: '200,230,255' },
      meteor: '230,240,255'
    }
  };
  const palette = () => (document.documentElement.getAttribute('data-theme') === 'dark' ? PALETTES.dark : PALETTES.light);

  let W = 0, H = 0, dpr = 1;
  let stars = [], sparkles = [], meteors = [], dust = [];
  let cloudLayers = [], cloudTheme = '';
  let tailImg = null, tailTheme = '';
  let nextMeteor = rand(5, 12);

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 1.5);
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  // ---------------------------------------------------------------- comet geometry
  // Head low-left of centre, tail sweeping up and off the top-right corner, widening as it goes.
  function comet() {
    const hx = W * 0.34, hy = H * 0.8;
    const ex = W * 1.1, ey = -H * 0.12;
    const L = Math.hypot(ex - hx, ey - hy);
    const dx = (ex - hx) / L, dy = (ey - hy) / L;
    return { hx, hy, L, dx, dy, nx: -dy, ny: dx, scale: Math.min(W, H) / 900 };
  }
  const halfWidth = (c, s) => (2 + Math.pow(s, 0.85) * 75) * Math.max(0.6, c.scale);
  // Point along the tail (s 0 head .. 1 end), `o` = sideways offset in half-widths; gentle bow
  function tailPoint(c, s, o) {
    const bow = Math.sin(s * Math.PI) * 26 * c.scale;
    const off = o * halfWidth(c, s) + bow;
    return [c.hx + c.dx * s * c.L + c.nx * off, c.hy + c.dy * s * c.L + c.ny * off];
  }

  function build() {
    const density = Math.min(1.6, (W * H) / (1400 * 800));
    stars = Array.from({ length: Math.round(260 * density) + 50 }, () => {
      const z = Math.pow(Math.random(), 2.2);
      const tint = Math.random();
      return {
        x: Math.random(), y: Math.pow(Math.random(), 1.4) * 0.85, z,
        r: 0.35 + z * 1.2, base: 0.25 + z * 0.55,
        tw: rand(0.6, 2.4), ph: rand(0, TAU), depth: rand(0.15, 0.6),
        tint: tint < 0.12 ? 'warm' : tint < 0.3 ? 'cool' : 'star'
      };
    });
    sparkles = Array.from({ length: Math.round(6 * density) + 3 }, () => ({
      x: Math.random(), y: Math.random() * 0.55, r: rand(1.3, 2.2),
      len: rand(8, 18), period: rand(3.5, 8), ph: rand(0, 1), tint: Math.random() < 0.3 ? 'warm' : 'cool'
    }));
    const keys = ['cyan', 'cyan', 'core', 'purple', 'green', 'magenta'];
    dust = Array.from({ length: Math.round(140 * Math.max(0.7, density)) }, () => ({
      s: Math.random(), o: (Math.random() + Math.random() - 1) * 1.3, sp: rand(0.012, 0.035),
      r: rand(0.5, 1.6), ph: rand(0, TAU), col: keys[Math.floor(Math.random() * keys.length)]
    }));
    meteors = [];
    cloudTheme = '';
    tailTheme = '';
  }

  // ---------------------------------------------------------------- clouds
  // Each layer is a W-wide canvas that tiles horizontally (puffs near an edge are drawn on both
  // sides), so drifting is just two drawImage calls.
  function renderCloudLayer(pal, opts) {
    const c = document.createElement('canvas');
    c.width = Math.round(W * dpr);
    c.height = Math.round(H * dpr);
    const g = c.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.filter = 'blur(1.2px)'; // softens puff edges (ignored where canvas filters aren't supported)
    const puffs = [];
    for (let b = 0; b < opts.banks; b++) {
      const cx = rand(0, W), cy = H * rand(opts.y0, opts.y1);
      const bw = rand(opts.w0, opts.w1) * Math.max(0.7, W / 1400);
      const n = Math.round(bw / 6);
      for (let i = 0; i < n; i++) {
        const u = Math.random() * 2 - 1;
        const edge = 1 - Math.abs(u) * 0.75;
        puffs.push({
          x: cx + u * bw / 2,
          y: cy + (Math.random() - 0.5) * bw * 0.05 - edge * bw * 0.035,
          r: rand(6, 30) * opts.scale * edge + 5
        });
      }
    }
    // Wispy streaks: long thin runs of heavily overlapping flattened puffs
    for (let i = 0; i < opts.wisps; i++) {
      const cx = rand(0, W), cy = H * rand(opts.y0 - 0.15, opts.y1 - 0.1), len = rand(140, 340);
      for (let k = 0; k < 40; k++) {
        const u = k / 39 - 0.5;
        puffs.push({ x: cx + u * len, y: cy + rand(-2, 2), r: (rand(10, 18) * (1 - Math.abs(u) * 1.2) + 4) * opts.scale, flat: 0.22, faint: 0.5 });
      }
    }
    puffs.sort((a, b) => a.y - b.y);
    puffs.forEach((p) => {
      const a = opts.alpha * (p.faint || 1);
      [p.x, p.x - W, p.x + W].forEach((x) => {
        if (x + p.r * 2 < 0 || x - p.r * 2 > W) return;
        g.save();
        g.translate(x, p.y);
        g.scale(1, p.flat || 0.5);
        // Shadowed body, centre pushed down so the belly is darkest
        let rg = g.createRadialGradient(0, p.r * 0.3, 0, 0, p.r * 0.3, p.r * 1.3);
        rg.addColorStop(0, `rgba(${pal.cloudBody},${a})`);
        rg.addColorStop(0.6, `rgba(${pal.cloudBody},${a * 0.7})`);
        rg.addColorStop(1, `rgba(${pal.cloudBody},0)`);
        g.fillStyle = rg;
        g.beginPath(); g.arc(0, p.r * 0.3, p.r * 1.3, 0, TAU); g.fill();
        // Lit top edge, toward the comet (up-right)
        rg = g.createRadialGradient(p.r * 0.25, -p.r * 0.35, 0, p.r * 0.25, -p.r * 0.35, p.r * 0.8);
        rg.addColorStop(0, `rgba(${pal.cloudHi},${a * 0.55})`);
        rg.addColorStop(1, `rgba(${pal.cloudHi},0)`);
        g.fillStyle = rg;
        g.beginPath(); g.arc(p.r * 0.25, -p.r * 0.35, p.r * 0.8, 0, TAU); g.fill();
        g.restore();
      });
    });
    return c;
  }

  function ensureClouds(pal) {
    if (cloudTheme === pal.key && cloudLayers.length) return;
    cloudTheme = pal.key;
    cloudLayers = [
      { img: renderCloudLayer(pal, { banks: 9, y0: 0.3, y1: 0.72, w0: 160, w1: 380, scale: 0.6, alpha: pal.cloudAlpha[0], wisps: 6 }), speed: 3.5, x: 0 },
      { img: renderCloudLayer(pal, { banks: 7, y0: 0.62, y1: 1.02, w0: 260, w1: 560, scale: 1.15, alpha: pal.cloudAlpha[1], wisps: 3 }), speed: 8, x: 0 }
    ];
  }

  function drawCloudLayer(layer) {
    const ox = ((layer.x % W) + W) % W;
    ctx.drawImage(layer.img, ox, 0, W, H);
    ctx.drawImage(layer.img, ox - W, 0, W, H);
  }

  // ---------------------------------------------------------------- drawing
  function drawSky(pal) {
    const g = ctx.createLinearGradient(0, 0, 0, H);
    g.addColorStop(0, pal.sky[0]);
    g.addColorStop(0.55, pal.sky[1]);
    g.addColorStop(1, pal.sky[2]);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
  }

  function drawStars(pal, t) {
    stars.forEach((s) => {
      const x = (((s.x + t * 0.0012 * s.depth) % 1) + 1) % 1 * W;
      const y = s.y * H;
      const tw = 0.5 + 0.5 * Math.sin(t * s.tw + s.ph);
      const horizon = 1 - smooth(0.45, 0.85, s.y);
      const a = Math.min(1, s.base * (0.35 + 0.65 * tw)) * pal.starAlpha * horizon;
      if (a < 0.02) return;
      ctx.beginPath();
      ctx.arc(x, y, s.r, 0, TAU);
      ctx.fillStyle = `rgba(${pal[s.tint]},${a})`;
      ctx.fill();
    });
  }

  // One coloured band of the tail as a filled ribbon on context g, fading in from the head and
  // out toward the far end
  function tailBand(g, c, offset, thick, col, alpha) {
    const steps = 30;
    const left = [], right = [];
    for (let i = 0; i <= steps; i++) {
      const s = i / steps;
      left.push(tailPoint(c, s, offset - thick));
      right.push(tailPoint(c, s, offset + thick));
    }
    const [x0, y0] = tailPoint(c, 0, offset);
    const [x1, y1] = tailPoint(c, 1, offset);
    const gr = g.createLinearGradient(x0, y0, x1, y1);
    gr.addColorStop(0, `rgba(${col},${alpha * 0.6})`);
    gr.addColorStop(0.05, `rgba(${col},${alpha})`);
    gr.addColorStop(0.7, `rgba(${col},${alpha * 0.8})`);
    gr.addColorStop(1, `rgba(${col},0)`);
    g.fillStyle = gr;
    g.beginPath();
    g.moveTo(left[0][0], left[0][1]);
    for (let i = 1; i < left.length; i++) g.lineTo(left[i][0], left[i][1]);
    for (let i = right.length - 1; i >= 0; i--) g.lineTo(right[i][0], right[i][1]);
    g.closePath();
    g.fill();
  }

  // The tail is static, so it's rendered once (blurred, so the colour bands melt into each other)
  // and each frame just draws it with a slow "breathing" alpha.
  function ensureTail(pal) {
    if (tailTheme === pal.key && tailImg) return;
    tailTheme = pal.key;
    const c = comet();
    const k = pal.comet;
    const A = pal.cometAlpha;
    tailImg = document.createElement('canvas');
    tailImg.width = Math.round(W * dpr);
    tailImg.height = Math.round(H * dpr);
    const g = tailImg.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.globalCompositeOperation = pal.mode;
    const blur = Math.max(3, 7 * c.scale);
    g.filter = `blur(${blur * 2}px)`;
    tailBand(g, c, 0, 2.4, k.glow, 0.12 * A);
    g.filter = `blur(${blur}px)`;
    tailBand(g, c, -0.95, 0.3, k.magenta, 0.4 * A);
    tailBand(g, c, -0.6, 0.4, k.purple, 0.55 * A);
    tailBand(g, c, 0.6, 0.32, k.green, 0.4 * A);
    tailBand(g, c, 0.15, 0.55, k.cyan, 0.6 * A);
    g.filter = `blur(${blur * 0.4}px)`;
    tailBand(g, c, 0, 0.2, k.core, 0.85 * A);
    g.filter = 'none';
    tailBand(g, c, 0, 0.05, k.core, 0.7 * A);
  }

  function drawComet(pal, t) {
    const c = comet();
    const k = pal.comet;
    const A = pal.cometAlpha;
    ensureTail(pal);
    ctx.globalCompositeOperation = pal.mode;
    ctx.globalAlpha = 0.88 + 0.12 * Math.sin(t * 0.7);
    ctx.drawImage(tailImg, 0, 0, W, H);
    ctx.globalAlpha = 1;

    // Dust streaming from the head up the tail
    dust.forEach((d) => {
      const [x, y] = tailPoint(c, d.s, d.o);
      const a = (0.35 + 0.65 * (0.5 + 0.5 * Math.sin(t * 3 + d.ph))) * (1 - smooth(0.75, 1, d.s)) * A;
      ctx.fillStyle = `rgba(${k[d.col]},${a})`;
      ctx.fillRect(x, y, d.r, d.r);
    });

    // Two thin fragments splitting off ahead of the head (falling down-left)
    [[-0.035, 0.22, 1.3], [0.05, 0.17, 0.9]].forEach(([ang, len, w]) => {
      const cs = Math.cos(ang), sn = Math.sin(ang);
      const fx = -(c.dx * cs - c.dy * sn), fy = -(c.dx * sn + c.dy * cs);
      const ex = c.hx + fx * c.L * len, ey = c.hy + fy * c.L * len;
      const g = ctx.createLinearGradient(c.hx, c.hy, ex, ey);
      g.addColorStop(0, `rgba(${k.cyan},${0.75 * A})`);
      g.addColorStop(1, `rgba(${k.cyan},0)`);
      ctx.strokeStyle = g;
      ctx.lineWidth = w * Math.max(1, c.scale * 1.4);
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.moveTo(c.hx, c.hy);
      ctx.lineTo(ex, ey);
      ctx.stroke();
    });
    ctx.globalCompositeOperation = 'source-over';
  }

  function drawCometHead(pal, t) {
    const c = comet();
    const k = pal.comet;
    const pulse = 0.85 + 0.15 * Math.sin(t * 2.2);
    ctx.globalCompositeOperation = pal.mode;
    const r = 34 * Math.max(0.7, c.scale) * pulse;
    const rg = ctx.createRadialGradient(c.hx, c.hy, 0, c.hx, c.hy, r);
    rg.addColorStop(0, `rgba(${k.core},${0.95 * pal.cometAlpha})`);
    rg.addColorStop(0.2, `rgba(${k.head},${0.6 * pal.cometAlpha})`);
    rg.addColorStop(1, `rgba(${k.glow},0)`);
    ctx.fillStyle = rg;
    ctx.fillRect(c.hx - r, c.hy - r, r * 2, r * 2);
    ctx.globalCompositeOperation = 'source-over';
  }

  function drawSparkles(pal, t) {
    ctx.globalCompositeOperation = pal.mode;
    sparkles.forEach((s) => {
      const phase = ((t / s.period + s.ph) % 1 + 1) % 1;
      const flare = Math.pow(Math.max(0, Math.sin(phase * Math.PI)), 6);
      const x = s.x * W, y = s.y * H;
      const col = pal[s.tint];
      const a = (0.45 + 0.55 * flare) * pal.starAlpha;

      const rr = s.r * (3 + flare * 5);
      const rg = ctx.createRadialGradient(x, y, 0, x, y, rr);
      rg.addColorStop(0, `rgba(${col},${a * 0.55})`);
      rg.addColorStop(1, `rgba(${col},0)`);
      ctx.fillStyle = rg;
      ctx.fillRect(x - rr, y - rr, rr * 2, rr * 2);

      const len = s.len * (0.35 + flare);
      ctx.save();
      ctx.translate(x, y);
      ctx.rotate(t * 0.15 + s.ph * TAU);
      [[len, 0.9], [len * 0.55, 0.6]].forEach(([l, w], i) => {
        ctx.rotate(i ? Math.PI / 4 : 0);
        ctx.fillStyle = `rgba(${pal.flare},${a * (i ? 0.45 : 0.85)})`;
        ctx.beginPath();
        ctx.moveTo(-l, 0); ctx.quadraticCurveTo(0, w, l, 0); ctx.quadraticCurveTo(0, -w, -l, 0);
        ctx.moveTo(0, -l); ctx.quadraticCurveTo(w, 0, 0, l); ctx.quadraticCurveTo(-w, 0, 0, -l);
        ctx.fill();
      });
      ctx.restore();
    });
    ctx.globalCompositeOperation = 'source-over';
  }

  function drawMeteors(pal) {
    meteors.forEach((m) => {
      const life = 1 - m.age / m.dur;
      const fade = Math.min(1, life * 3) * Math.min(1, (m.age / m.dur) * 6);
      const tx = m.x - Math.cos(m.ang) * m.tail, ty = m.y - Math.sin(m.ang) * m.tail;
      const g = ctx.createLinearGradient(m.x, m.y, tx, ty);
      g.addColorStop(0, `rgba(${pal.meteor},${0.9 * fade})`);
      g.addColorStop(1, `rgba(${pal.meteor},0)`);
      ctx.strokeStyle = g;
      ctx.lineWidth = 1.6;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.moveTo(m.x, m.y);
      ctx.lineTo(tx, ty);
      ctx.stroke();
    });
  }

  function update(dt) {
    cloudLayers.forEach((l) => { l.x += l.speed * dt; });
    dust.forEach((d) => {
      d.s += d.sp * dt;
      if (d.s > 1) { d.s = 0; d.o = (Math.random() + Math.random() - 1) * 1.3; }
    });

    nextMeteor -= dt;
    if (nextMeteor <= 0) {
      nextMeteor = rand(8, 18);
      // Always heading downward (canvas y grows down), to the right or to the left
      const dirRight = Math.random() < 0.5;
      const dip = rand(0.35, 0.7);
      meteors.push({
        x: dirRight ? rand(0, W * 0.5) : rand(W * 0.5, W), y: rand(0, H * 0.3),
        ang: dirRight ? dip : Math.PI - dip,
        sp: rand(500, 850), tail: rand(80, 150), age: 0, dur: rand(0.6, 1.0)
      });
    }
    meteors.forEach((m) => {
      m.age += dt;
      m.x += Math.cos(m.ang) * m.sp * dt;
      m.y += Math.sin(m.ang) * m.sp * dt;
    });
    meteors = meteors.filter((m) => m.age < m.dur);
  }

  function draw(t) {
    const pal = palette();
    ensureClouds(pal);
    ctx.globalCompositeOperation = 'source-over';
    drawSky(pal);
    drawStars(pal, t);
    drawSparkles(pal, t);
    drawMeteors(pal);
    drawCloudLayer(cloudLayers[0]);
    drawComet(pal, t);
    drawCloudLayer(cloudLayers[1]);
    drawCometHead(pal, t); // glow over the near clouds, as if lighting them
  }

  // ---------------------------------------------------------------- loop
  resize();
  build();
  let last = performance.now();
  let lastDraw = 0;
  let raf = 0;

  function frame(now) {
    raf = requestAnimationFrame(frame);
    if (now - lastDraw < 33) return;
    const dt = Math.min(0.1, (now - last) / 1000);
    last = now;
    lastDraw = now;
    update(dt);
    draw(now / 1000);
  }

  function still() {
    draw(0);
  }

  let resizeTimer = 0;
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      resize();
      build(); // clouds and stars are laid out for the viewport size
      if (reduceMotion) still();
    }, 150);
  });

  // Redraw the still frame when the theme toggles (animated mode picks it up on the next frame)
  if (reduceMotion) {
    new MutationObserver(still).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    still();
    return;
  }

  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      cancelAnimationFrame(raf);
    } else {
      last = performance.now();
      raf = requestAnimationFrame(frame);
    }
  });
  raf = requestAnimationFrame(frame);
})();
