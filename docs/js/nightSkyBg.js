// "Starry night" animated background for portal pages (loaded by js/nav.js; skipped on Dashboard,
// GMA Conversations, the full-screen calculators and the print-only pages). A single fixed
// <canvas class="app-sky-bg"> behind .page / #topnav (css/styles.css): a night-sky gradient, a faint
// Milky Way band, three depth layers of twinkling stars (far = small/dim/slow drift), a few bright
// stars with 4-point sparkle flares, and an occasional shooting star.
// Light theme is a pale twilight (stars drawn in soft indigo/gold) so dark page text stays readable;
// dark theme is a real night sky.
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

  const PALETTES = {
    light: {
      top: '#dfe4f6', mid: '#e9ecf8', bottom: '#f4f1f4', band: '120,130,200', bandAlpha: 0.10,
      star: '70,85,160', warm: '190,140,40', cool: '80,110,190', flare: '90,100,180',
      starAlpha: 0.75, glowMode: 'source-over', meteor: '90,100,180'
    },
    dark: {
      top: '#02040c', mid: '#0a1230', bottom: '#16183a', band: '170,180,255', bandAlpha: 0.13,
      star: '255,255,255', warm: '255,214,150', cool: '170,200,255', flare: '220,230,255',
      starAlpha: 1, glowMode: 'lighter', meteor: '230,240,255'
    }
  };
  const palette = () => (document.documentElement.getAttribute('data-theme') === 'dark' ? PALETTES.dark : PALETTES.light);

  let W = 0, H = 0;
  let stars = [], sparkles = [], bandDust = [], meteors = [];
  let nextMeteor = rand(4, 10);

  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function build() {
    const density = Math.min(1.6, (W * H) / (1400 * 800));
    // Positions are 0..1 so a resize just stretches the sky; z = depth layer (0 far .. 1 near)
    stars = Array.from({ length: Math.round(320 * density) + 60 }, () => {
      const z = Math.pow(Math.random(), 2.2);
      const tint = Math.random();
      return {
        x: Math.random(), y: Math.random(), z,
        r: 0.35 + z * 1.25,
        base: 0.25 + z * 0.55,
        tw: rand(0.6, 2.4), ph: rand(0, TAU), depth: rand(0.15, 0.6),
        tint: tint < 0.12 ? 'warm' : tint < 0.3 ? 'cool' : 'star'
      };
    });
    sparkles = Array.from({ length: Math.round(9 * density) + 4 }, () => ({
      x: Math.random(), y: Math.random() * 0.9, r: rand(1.4, 2.4),
      len: rand(9, 20), period: rand(3.5, 8), ph: rand(0, 1), tint: Math.random() < 0.3 ? 'warm' : 'cool'
    }));
    // Milky Way: a diagonal band of tiny dense dust stars
    bandDust = Array.from({ length: Math.round(420 * density) }, () => {
      const u = Math.random();
      const off = (Math.random() + Math.random() + Math.random() - 1.5) * 0.11;
      return { u, off, r: rand(0.25, 0.7), a: rand(0.15, 0.5), ph: rand(0, TAU) };
    });
    meteors = [];
  }

  function bandPoint(u, off) {
    // From lower-left to upper-right, gently curved
    const x = -0.1 + u * 1.2;
    const y = 0.85 - u * 0.75 + Math.sin(u * Math.PI) * 0.08;
    return { x: (x - off * 0.6) * W, y: (y - off) * H };
  }

  function drawSky(pal) {
    const g = ctx.createLinearGradient(0, 0, 0, H);
    g.addColorStop(0, pal.top);
    g.addColorStop(0.6, pal.mid);
    g.addColorStop(1, pal.bottom);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);

    // Milky Way glow: a few soft blobs along the band
    ctx.globalCompositeOperation = pal.glowMode;
    for (let i = 0; i <= 8; i++) {
      const p = bandPoint(i / 8, 0);
      const rr = Math.max(W, H) * 0.16;
      const rg = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, rr);
      rg.addColorStop(0, `rgba(${pal.band},${pal.bandAlpha})`);
      rg.addColorStop(1, `rgba(${pal.band},0)`);
      ctx.fillStyle = rg;
      ctx.fillRect(p.x - rr, p.y - rr, rr * 2, rr * 2);
    }
    ctx.globalCompositeOperation = 'source-over';
  }

  function drawStars(pal, t) {
    bandDust.forEach((d) => {
      const p = bandPoint(d.u, d.off);
      const a = d.a * (0.75 + 0.25 * Math.sin(t * 1.3 + d.ph)) * pal.starAlpha;
      ctx.fillStyle = `rgba(${pal.star},${a})`;
      ctx.fillRect(p.x, p.y, d.r * 2, d.r * 2);
    });

    stars.forEach((s) => {
      // Very slow sideways drift, faster for nearer stars (parallax)
      const x = (((s.x + t * 0.0015 * s.depth) % 1) + 1) % 1 * W;
      const y = s.y * H;
      const tw = 0.5 + 0.5 * Math.sin(t * s.tw + s.ph);
      const a = Math.min(1, s.base * (0.35 + 0.65 * tw)) * pal.starAlpha;
      const col = pal[s.tint];
      ctx.beginPath();
      ctx.arc(x, y, s.r, 0, TAU);
      ctx.fillStyle = `rgba(${col},${a})`;
      ctx.fill();
      if (s.z > 0.55) {
        ctx.beginPath();
        ctx.arc(x, y, s.r * 3.2, 0, TAU);
        ctx.fillStyle = `rgba(${col},${a * 0.12})`;
        ctx.fill();
      }
    });
  }

  function drawSparkles(pal, t) {
    ctx.globalCompositeOperation = pal.glowMode;
    sparkles.forEach((s) => {
      // Each one flares up briefly once per period, otherwise sits as a bright star
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

      // 4-point cross flare, slowly rotating
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

      ctx.beginPath();
      ctx.arc(x, y, s.r * 0.8, 0, TAU);
      ctx.fillStyle = `rgba(${pal.star},${Math.min(1, a + 0.2)})`;
      ctx.fill();
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
    nextMeteor -= dt;
    if (nextMeteor <= 0) {
      nextMeteor = rand(6, 16);
      // Always heading downward (canvas y grows down), to the right or to the left
      const dirRight = Math.random() < 0.5;
      const dip = rand(0.35, 0.7);
      meteors.push({
        x: dirRight ? rand(0, W * 0.6) : rand(W * 0.4, W), y: rand(0, H * 0.35),
        ang: dirRight ? dip : Math.PI - dip,
        sp: rand(500, 850), tail: rand(90, 170), age: 0, dur: rand(0.7, 1.2)
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
    ctx.globalCompositeOperation = 'source-over';
    drawSky(pal);
    drawStars(pal, t);
    drawSparkles(pal, t);
    drawMeteors(pal);
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

  window.addEventListener('resize', () => {
    const oldW = W, oldH = H;
    resize();
    if (Math.abs(W * H - oldW * oldH) > oldW * oldH * 0.3) build();
    if (reduceMotion) still();
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
