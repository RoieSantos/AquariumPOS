// "Inside the aquarium" animated background for portal pages (loaded by js/nav.js; skipped on
// Dashboard and the print-only pages). A single fixed <canvas class="app-aqua-bg"> behind .page /
// #topnav (css/styles.css) - depth comes from layering: far plants/driftwood/sand, then 9 koi (one
// of each variety in KOI_VARIETIES) sorted far -> near with a water-haze veil between each one (so
// far fish look smaller, slower and foggier), then drifting particles, bubbles and near plants.
// Fish turn around by squashing their width through zero, which reads as a 3D turn.
// Capped at ~30 fps, paused while the tab is hidden, a still frame for "reduce motion" users.
(function () {
  if (document.querySelector('.app-aqua-bg')) return;
  const canvas = document.createElement('canvas');
  canvas.className = 'app-aqua-bg';
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
      top: '#e4f3fa', mid: '#a8d3e5', bottom: '#79afc8', fog: '170,210,228',
      sand1: '#dccba3', sand2: '#b39d72', ray: '255,255,255', rayMode: 'source-over',
      plantFar: '#86b9a0', plantNear: '#2f7d55', rock: '#7d8d96', wood: '#5a4030',
      particle: '255,255,255', bubble: '255,255,255'
    },
    dark: {
      top: '#0f3049', mid: '#092237', bottom: '#030c17', fog: '8,28,46',
      sand1: '#2c2a21', sand2: '#14130e', ray: '120,190,255', rayMode: 'lighter',
      plantFar: '#14362f', plantNear: '#0d5236', rock: '#1b2630', wood: '#1d140e',
      particle: '170,215,255', bubble: '170,215,255'
    }
  };
  const palette = () => (document.documentElement.getAttribute('data-theme') === 'dark' ? PALETTES.dark : PALETTES.light);

  let W = 0, H = 0;
  let fish = [], particles = [], bubbles = [], farPlants = [], nearPlants = [], rocks = [];
  let rays = [];

  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    fish.forEach((f) => {
      f.x = Math.min(Math.max(f.x, -50), W + 50);
      f.y = Math.min(Math.max(f.y, H * 0.12), H * 0.75);
      f.ty = f.y;
    });
  }

  function build() {
    const varieties = KOI_VARIETIES.slice().sort(() => Math.random() - 0.5);
    const count = varieties.length;
    fish = [];
    for (let i = 0; i < count; i++) {
      const dir = Math.random() < 0.5 ? 1 : -1;
      const variety = varieties[i];
      fish.push({
        z: 0.12 + 0.88 * (i / (count - 1)) + rand(-0.03, 0.03),
        x: rand(0, W), y: rand(H * 0.14, H * 0.72), ty: 0, nextTy: rand(2, 8),
        dir, flip: dir, sp: rand(0.8, 1.2), ph: rand(0, TAU), shimmer: rand(0, TAU),
        variety, patches: variety.patches ? variety.patches() : []
      });
    }
    fish.forEach((f) => { f.ty = f.y; });
    fish.sort((a, b) => a.z - b.z);

    particles = Array.from({ length: W < 700 ? 40 : 80 }, () => ({ x: rand(0, 1), y: rand(0, 1), z: rand(0, 1), p: rand(0, TAU) }));
    rays = Array.from({ length: 6 }, (_, i) => ({ x: (i + rand(0.1, 0.9)) / 6, w: rand(0.04, 0.11), skew: rand(0.05, 0.18), p: rand(0, TAU) }));
    farPlants = Array.from({ length: 22 }, () => ({ x: rand(0, 1), h: rand(0.12, 0.34), w: rand(8, 18), p: rand(0, TAU) }));
    nearPlants = [];
    for (let i = 0; i < 7; i++) {
      const left = i % 2 === 0;
      nearPlants.push({ x: left ? rand(-0.02, 0.07) : rand(0.93, 1.02), h: rand(0.28, 0.5), w: rand(16, 28), p: rand(0, TAU) });
    }
    rocks = Array.from({ length: 6 }, () => ({ x: rand(0.03, 0.97), rx: rand(30, 80), ry: rand(14, 30) }));
    bubbles = [];
  }

  // ---------------------------------------------------------------- scene layers
  function drawWater(pal, t) {
    const g = ctx.createLinearGradient(0, 0, 0, H);
    g.addColorStop(0, pal.top);
    g.addColorStop(0.55, pal.mid);
    g.addColorStop(1, pal.bottom);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);

    // Light rays from the surface
    ctx.save();
    ctx.globalCompositeOperation = pal.rayMode;
    rays.forEach((r, i) => {
      const a = 0.09 + 0.07 * Math.sin(t * 0.35 + r.p + i);
      const x0 = r.x * W + Math.sin(t * 0.12 + r.p) * W * 0.02;
      const w = r.w * W;
      const sk = r.skew * W;
      const lg = ctx.createLinearGradient(0, 0, 0, H * 0.85);
      lg.addColorStop(0, `rgba(${pal.ray},${a})`);
      lg.addColorStop(1, `rgba(${pal.ray},0)`);
      ctx.fillStyle = lg;
      ctx.beginPath();
      ctx.moveTo(x0 - w / 2, 0);
      ctx.lineTo(x0 + w / 2, 0);
      ctx.lineTo(x0 + w * 1.4 + sk, H);
      ctx.lineTo(x0 - w * 0.6 + sk, H);
      ctx.closePath();
      ctx.fill();
    });
    // Rippling surface band
    const sg = ctx.createLinearGradient(0, 0, 0, 40);
    sg.addColorStop(0, `rgba(${pal.ray},${0.22 + 0.06 * Math.sin(t * 0.8)})`);
    sg.addColorStop(1, `rgba(${pal.ray},0)`);
    ctx.fillStyle = sg;
    ctx.fillRect(0, 0, W, 40);
    ctx.restore();
  }

  function drawFloor(pal, t) {
    const y0 = H * 0.88;
    ctx.fillStyle = pal.wood;
    ctx.strokeStyle = pal.wood;
    ctx.lineCap = 'round';
    // Driftwood
    ctx.lineWidth = Math.max(10, W * 0.012);
    ctx.beginPath();
    ctx.moveTo(W * 0.58, y0 + 10);
    ctx.bezierCurveTo(W * 0.66, y0 - H * 0.05, W * 0.7, y0 - H * 0.2, W * 0.79, y0 - H * 0.3);
    ctx.stroke();
    ctx.lineWidth *= 0.55;
    ctx.beginPath();
    ctx.moveTo(W * 0.69, y0 - H * 0.12);
    ctx.quadraticCurveTo(W * 0.64, y0 - H * 0.22, W * 0.6, y0 - H * 0.24);
    ctx.moveTo(W * 0.75, y0 - H * 0.24);
    ctx.quadraticCurveTo(W * 0.82, y0 - H * 0.28, W * 0.85, y0 - H * 0.36);
    ctx.stroke();

    // Far plants
    farPlants.forEach((p) => drawBlade(p, pal.plantFar, t, y0 + 6));

    // Sand
    const sg = ctx.createLinearGradient(0, y0 - 10, 0, H);
    sg.addColorStop(0, pal.sand1);
    sg.addColorStop(1, pal.sand2);
    ctx.fillStyle = sg;
    ctx.beginPath();
    ctx.moveTo(0, y0 + 8);
    ctx.bezierCurveTo(W * 0.3, y0 - 12, W * 0.6, y0 + 18, W, y0 - 4);
    ctx.lineTo(W, H);
    ctx.lineTo(0, H);
    ctx.closePath();
    ctx.fill();

    // Rocks
    rocks.forEach((r) => {
      const rx = r.x * W;
      const ry = y0 + 6 + r.ry * 0.3;
      const rg = ctx.createRadialGradient(rx - r.rx * 0.3, ry - r.ry * 0.5, 2, rx, ry, r.rx);
      rg.addColorStop(0, `rgba(${pal.ray},0.25)`);
      rg.addColorStop(0.35, pal.rock);
      rg.addColorStop(1, pal.rock);
      ctx.fillStyle = rg;
      ctx.beginPath();
      ctx.ellipse(rx, ry, r.rx, r.ry, 0, Math.PI, TAU);
      ctx.closePath();
      ctx.fill();
    });
  }

  function drawBlade(p, color, t, baseY) {
    const x = p.x * W;
    const h = p.h * H;
    const sway = Math.sin(t * 0.6 + p.p) * h * 0.09;
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.moveTo(x - p.w / 2, baseY);
    ctx.quadraticCurveTo(x - p.w / 2 + sway * 0.4, baseY - h * 0.55, x + sway, baseY - h);
    ctx.quadraticCurveTo(x + p.w / 2 + sway * 0.4, baseY - h * 0.5, x + p.w / 2, baseY);
    ctx.closePath();
    ctx.fill();
  }

  function veil(pal, alpha) {
    if (alpha <= 0) return;
    ctx.fillStyle = `rgba(${pal.fog},${Math.min(alpha, 0.8)})`;
    ctx.fillRect(0, 0, W, H);
  }

  // ---------------------------------------------------------------- koi
  // A colour patch = a cluster of overlapping circles at (s along the body, v across it: -1 back,
  // +1 belly), radius in body lengths.
  const blob = (s, v, r, n = 4) => Array.from({ length: n }, () => ({
    s: s + rand(-r, r) * 0.9, v: v + rand(-0.22, 0.22), r: r * rand(0.6, 1)
  }));
  const RED = '#d4381f';
  const SUMI = '#14110f';
  const KOI_VARIETIES = [
    { name: 'Kohaku', base: '#f6f2ea', belly: '#ffffff', fin: '246,242,234',
      patches: () => [{ color: RED, blobs: [...blob(0.13, -0.45, 0.06), ...blob(0.38, -0.6, 0.08, 5), ...blob(0.63, -0.45, 0.055)] }] },
    { name: 'Taisho Sanke', base: '#f6f2ea', belly: '#ffffff', fin: '246,242,234',
      patches: () => [
        { color: RED, blobs: [...blob(0.14, -0.5, 0.06), ...blob(0.47, -0.5, 0.08, 5)] },
        { color: SUMI, blobs: [...blob(0.32, -0.75, 0.025, 2), ...blob(0.6, -0.2, 0.03, 2), ...blob(0.72, -0.8, 0.02, 2)] }
      ] },
    { name: 'Showa', base: SUMI, belly: '#e8e3d9', fin: '236,230,220', finRoot: SUMI,
      patches: () => [
        { color: '#f1ede5', blobs: [...blob(0.3, 0.35, 0.08, 5), ...blob(0.68, 0.1, 0.05)] },
        { color: RED, blobs: [...blob(0.1, -0.35, 0.06), ...blob(0.46, -0.6, 0.07)] }
      ] },
    { name: 'Tancho', base: '#f7f4ee', belly: '#ffffff', fin: '247,244,238',
      patches: () => [{ color: '#d12d1c', blobs: [{ s: 0.1, v: -0.78, r: 0.042 }] }] },
    { name: 'Yamabuki Ogon', base: '#e3a62a', belly: '#f6d77e', fin: '240,192,80', metallic: true },
    { name: 'Platinum Ogon', base: '#d9dee2', belly: '#f4f6f7', fin: '232,236,238', metallic: true },
    { name: 'Chagoi', base: '#7b5a38', belly: '#b89466', fin: '150,115,75', net: 'rgba(45,28,12,0.5)' },
    { name: 'Asagi', base: '#67849d', belly: '#d65a2c', fin: '214,98,52', net: 'rgba(225,238,247,0.55)', bellyAt: 0.55 },
    { name: 'Kujaku', base: '#e7eaec', belly: '#f7f7f7', fin: '238,240,242', metallic: true, net: 'rgba(40,52,64,0.4)',
      patches: () => [{ color: '#e0702a', blobs: [...blob(0.2, -0.5, 0.07), ...blob(0.52, -0.3, 0.08, 5)] }] }
  ];

  // Drawn facing +x in its own coordinates, length L, s = 0 (snout) .. 0.86 (tail base).
  function drawKoi(f) {
    const { L, ph, shimmer, variety: k, patches } = f;
    const X = (s) => L * (0.5 - s);
    const mid = (s) => L * 0.035 * s * s * Math.sin(ph - s * 5);
    const hT = (s) => L * (0.15 * Math.sqrt(Math.min(1, s / 0.32)) - 0.115 * smooth(0.38, 0.86, s));
    const hB = (s) => L * (0.115 * Math.sqrt(Math.min(1, s / 0.26)) - 0.08 * smooth(0.42, 0.86, s));
    const yT = (s) => mid(s) - hT(s);
    const yB = (s) => mid(s) + hB(s);
    const at = (s, v) => [X(s), mid(s) + v * (v < 0 ? hT(s) : hB(s))];
    const fin = (a) => `rgba(${k.fin},${a})`;
    const lw = Math.max(0.5, L * 0.0035);
    const flutter = Math.sin(ph * 1.1) * L * 0.01;
    const flap = Math.sin(ph * 0.9);

    // Rounded paddle fin (pectoral / pelvic) at the origin, trailing back and down
    function paddle(len, alpha, rootColor) {
      const g = ctx.createLinearGradient(0, 0, -len * 0.9, len * 0.6);
      g.addColorStop(0, rootColor || fin(alpha + 0.15));
      g.addColorStop(rootColor ? 0.35 : 0, rootColor || fin(alpha + 0.15));
      g.addColorStop(1, fin(alpha * 0.6));
      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.moveTo(0, 0);
      ctx.bezierCurveTo(-len * 0.25, len * 0.4, -len * 0.75, len * 0.72, -len, len * 0.58);
      ctx.bezierCurveTo(-len * 0.95, len * 0.3, -len * 0.4, len * 0.06, 0, len * 0.12);
      ctx.closePath();
      ctx.fill();
      ctx.strokeStyle = 'rgba(0,0,0,0.12)';
      ctx.lineWidth = lw * 0.7;
      ctx.beginPath();
      for (let u = 0.15; u <= 1; u += 0.17) {
        ctx.moveTo(0, len * 0.06);
        ctx.lineTo(-len * (0.2 + 0.75 * u), len * (0.25 + 0.4 * u - 0.1 * u * u));
      }
      ctx.stroke();
    }
    function finAt(s, base, len, flapAmt, alpha, root) {
      ctx.save();
      ctx.translate(X(s), yB(s) - L * 0.012);
      ctx.rotate(base + flapAmt);
      paddle(len * L, alpha, root);
      ctx.restore();
    }

    // Far-side pectoral (behind the body, fainter)
    finAt(0.18, 0.3, 0.15, -flap * 0.2, 0.3, null);

    // Dorsal fin along the back
    const dg = ctx.createLinearGradient(0, yT(0.4), 0, yT(0.4) - L * 0.09);
    dg.addColorStop(0, fin(0.85));
    dg.addColorStop(1, fin(0.4));
    ctx.fillStyle = dg;
    ctx.beginPath();
    ctx.moveTo(X(0.3), yT(0.3) + 2);
    ctx.quadraticCurveTo(X(0.31), yT(0.3) - L * 0.08, X(0.37), yT(0.37) - L * 0.085 + flutter);
    ctx.quadraticCurveTo(X(0.55), yT(0.55) - L * 0.05 + flutter * 0.6, X(0.7), yT(0.7) - L * 0.006);
    for (let s = 0.7; s >= 0.3; s -= 0.05) ctx.lineTo(X(s), yT(s) + 2);
    ctx.closePath();
    ctx.fill();
    ctx.strokeStyle = 'rgba(0,0,0,0.1)';
    ctx.lineWidth = lw * 0.7;
    ctx.beginPath();
    for (let s = 0.33; s < 0.68; s += 0.035) {
      const u = (s - 0.3) / 0.4;
      ctx.moveTo(X(s), yT(s));
      ctx.lineTo(X(s + 0.03), yT(s) - L * (0.08 - 0.055 * u) + flutter * (1 - u * 0.4));
    }
    ctx.stroke();

    // Anal fin
    ctx.fillStyle = fin(0.6);
    ctx.beginPath();
    ctx.moveTo(X(0.67), yB(0.67) - 2);
    ctx.quadraticCurveTo(X(0.71), yB(0.7) + L * 0.05, X(0.79), yB(0.78) + L * 0.045 - flutter * 0.5);
    ctx.lineTo(X(0.8), yB(0.8) - 2);
    ctx.closePath();
    ctx.fill();

    // Tail - broad, slightly forked
    ctx.save();
    ctx.translate(X(0.85), mid(0.85));
    ctx.rotate(Math.cos(ph - 4.3) * 0.3);
    const tg = ctx.createLinearGradient(0, 0, -L * 0.22, 0);
    tg.addColorStop(0, k.finRoot || fin(0.85));
    tg.addColorStop(k.finRoot ? 0.2 : 0, k.finRoot || fin(0.85));
    tg.addColorStop(1, fin(0.35));
    ctx.fillStyle = tg;
    ctx.beginPath();
    ctx.moveTo(0, -L * 0.03);
    ctx.bezierCurveTo(-L * 0.06, -L * 0.06, -L * 0.15, -L * 0.12, -L * 0.22, -L * 0.12);
    ctx.quadraticCurveTo(-L * 0.17, -L * 0.04, -L * 0.15, 0);
    ctx.quadraticCurveTo(-L * 0.17, L * 0.04, -L * 0.22, L * 0.12);
    ctx.bezierCurveTo(-L * 0.15, L * 0.12, -L * 0.06, L * 0.06, 0, L * 0.03);
    ctx.closePath();
    ctx.fill();
    ctx.strokeStyle = 'rgba(0,0,0,0.1)';
    ctx.lineWidth = lw * 0.7;
    ctx.beginPath();
    for (let u = -1; u <= 1.001; u += 0.2) {
      ctx.moveTo(-L * 0.01, u * L * 0.02);
      ctx.lineTo(-L * (0.15 + 0.065 * Math.abs(u)), u * L * 0.112);
    }
    ctx.stroke();
    ctx.restore();

    // Body
    const N = 36;
    const body = new Path2D();
    body.moveTo(X(0), mid(0));
    for (let i = 1; i <= N; i++) { const s = (0.86 * i) / N; body.lineTo(X(s), yT(s)); }
    for (let i = N; i >= 0; i--) { const s = (0.86 * i) / N; body.lineTo(X(s), yB(s)); }
    body.closePath();

    const bellyAt = k.bellyAt || 0.62;
    const bg = ctx.createLinearGradient(0, -L * 0.13, 0, L * 0.1);
    bg.addColorStop(0, k.base);
    bg.addColorStop(bellyAt, k.base);
    bg.addColorStop(Math.min(1, bellyAt + 0.15), k.belly);
    bg.addColorStop(1, k.belly);
    ctx.fillStyle = bg;
    ctx.fill(body);

    ctx.save();
    ctx.clip(body);

    // Colour patches - a soft halo pass then the solid pass, for slightly feathered edges
    patches.forEach((p) => {
      [[1.14, 0.4], [1, 1]].forEach(([grow, alpha]) => {
        ctx.globalAlpha = alpha;
        ctx.fillStyle = p.color;
        ctx.beginPath();
        p.blobs.forEach((b) => {
          const [x, y] = at(b.s, b.v);
          ctx.moveTo(x + b.r * L * grow, y);
          ctx.arc(x, y, b.r * L * grow, 0, TAU);
        });
        ctx.fill();
      });
    });
    ctx.globalAlpha = 1;

    // Scales (free edge toward the tail) - strong net on Asagi/Chagoi/Kujaku, faint texture otherwise
    ctx.strokeStyle = k.net || 'rgba(0,0,0,0.07)';
    ctx.lineWidth = lw * (k.net ? 1 : 0.8);
    const step = 0.034;
    let row = 0;
    ctx.beginPath();
    for (let v = -0.95; v <= 0.6; v += 0.24, row++) {
      for (let s = 0.22 + (row % 2) * step * 0.5; s < 0.86; s += step) {
        const [cx, cy] = at(s, v);
        const r = Math.max(1.2, L * 0.02 * Math.min(1, (hT(s) + hB(s)) / (L * 0.2)));
        ctx.moveTo(cx, cy + r);
        ctx.arc(cx, cy, r, Math.PI * 0.5, Math.PI * 1.5);
      }
    }
    ctx.stroke();

    // Roundness: dark back, highlight along the upper flank, shadowed belly
    const sg = ctx.createLinearGradient(0, -L * 0.13, 0, L * 0.1);
    sg.addColorStop(0, 'rgba(0,0,0,0.32)');
    sg.addColorStop(0.2, 'rgba(0,0,0,0.04)');
    sg.addColorStop(0.36, `rgba(255,255,255,${k.metallic ? 0.38 : 0.2})`);
    sg.addColorStop(0.55, 'rgba(255,255,255,0)');
    sg.addColorStop(0.85, 'rgba(0,0,0,0.07)');
    sg.addColorStop(1, 'rgba(0,0,0,0.3)');
    ctx.fillStyle = sg;
    ctx.fillRect(-L, -L * 0.3, L * 2, L * 0.6);

    // Travelling sheen (much stronger on metallic Ogon / Kujaku)
    const bx = X(0.45) + Math.sin(shimmer) * L * 0.35;
    const sh = ctx.createLinearGradient(bx - L * 0.14, 0, bx + L * 0.14, 0);
    const shA = k.metallic ? 0.45 : 0.14;
    sh.addColorStop(0, 'rgba(255,250,235,0)');
    sh.addColorStop(0.5, `rgba(255,250,235,${shA})`);
    sh.addColorStop(1, 'rgba(255,250,235,0)');
    ctx.fillStyle = sh;
    ctx.fillRect(-L, -L * 0.3, L * 2, L * 0.6);

    // Soft highlight on the forehead
    const [hx, hy] = at(0.08, -0.45);
    const hg = ctx.createRadialGradient(hx, hy, 0, hx, hy, L * 0.1);
    hg.addColorStop(0, 'rgba(255,255,255,0.22)');
    hg.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.fillStyle = hg;
    ctx.fillRect(X(0.2), -L * 0.2, L * 0.25, L * 0.4);
    ctx.restore();

    ctx.strokeStyle = 'rgba(0,0,0,0.18)';
    ctx.lineWidth = lw;
    ctx.stroke(body);

    // Gill cover
    ctx.strokeStyle = 'rgba(0,0,0,0.2)';
    ctx.lineWidth = lw * 1.1;
    ctx.beginPath();
    ctx.moveTo(...at(0.17, -0.8));
    ctx.quadraticCurveTo(...at(0.215, 0), ...at(0.17, 0.85));
    ctx.stroke();

    // Mouth, two barbels, nostril, eye
    const mx = X(0) + L * 0.004;
    const my = mid(0) + L * 0.014;
    ctx.fillStyle = 'rgba(190,130,110,0.75)';
    ctx.beginPath();
    ctx.ellipse(mx, my, L * 0.012, L * 0.01, 0, 0, TAU);
    ctx.fill();
    ctx.strokeStyle = 'rgba(225,195,170,0.95)';
    ctx.lineWidth = Math.max(0.7, L * 0.004);
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(X(0.012), my + L * 0.006);
    ctx.quadraticCurveTo(X(0.01), my + L * 0.03, X(0) + L * 0.012, my + L * 0.04 + flap * L * 0.004);
    ctx.moveTo(X(0.03), my + L * 0.01);
    ctx.quadraticCurveTo(X(0.03), my + L * 0.026, X(0.02), my + L * 0.033 - flap * L * 0.003);
    ctx.stroke();

    ctx.fillStyle = 'rgba(0,0,0,0.35)';
    ctx.beginPath();
    ctx.arc(...at(0.035, -0.5), Math.max(0.8, L * 0.004), 0, TAU);
    ctx.fill();

    const [ex, ey] = at(0.075, -0.18);
    const er = Math.max(1.4, L * 0.016);
    const eg = ctx.createRadialGradient(ex, ey, er * 0.3, ex, ey, er);
    eg.addColorStop(0, '#e9d9a6');
    eg.addColorStop(1, '#9a8455');
    ctx.fillStyle = eg;
    ctx.beginPath(); ctx.arc(ex, ey, er, 0, TAU); ctx.fill();
    ctx.fillStyle = '#0a0a0a';
    ctx.beginPath(); ctx.arc(ex + er * 0.12, ey + er * 0.05, er * 0.62, 0, TAU); ctx.fill();
    ctx.fillStyle = 'rgba(255,255,255,0.85)';
    ctx.beginPath(); ctx.arc(ex + er * 0.3, ey - er * 0.28, er * 0.2, 0, TAU); ctx.fill();

    // Near-side pectoral + pelvic fins (in front of the body)
    finAt(0.17, 0.05, 0.16, flap * 0.22, 0.55, k.finRoot);
    finAt(0.46, 0, 0.08, flap * 0.15, 0.5, null);
  }

  // ---------------------------------------------------------------- update + draw
  function update(dt, t) {
    const base = Math.min(Math.max(W * 0.17, 130), 290);
    fish.forEach((f) => {
      const L = base * (0.4 + 0.7 * f.z);
      const speed = (14 + 26 * f.z) * f.sp;
      // Turn around once the head is just past the glass; occasionally mid-tank too
      if ((f.dir > 0 && f.x > W + L * 0.1) || (f.dir < 0 && f.x < -L * 0.1) ||
          (Math.random() < dt * 0.015 && f.x > L && f.x < W - L)) {
        f.dir = -f.dir;
      }
      f.flip += Math.sign(f.dir - f.flip) * Math.min(Math.abs(f.dir - f.flip), dt * 0.9);
      f.x += f.flip * speed * dt;
      f.nextTy -= dt;
      if (f.nextTy <= 0) { f.ty = rand(H * 0.14, H * 0.72); f.nextTy = rand(5, 14); }
      f.vy = (f.ty - f.y) * 0.12;
      f.y += f.vy * dt;
      f.ph += dt * (2 + speed * 0.03);
      f.shimmer += dt * 0.6;
      f.L = L;
    });

    particles.forEach((p) => {
      p.y -= dt * (0.004 + p.z * 0.01);
      p.x += Math.sin(t * 0.3 + p.p) * dt * 0.003;
      if (p.y < -0.02) { p.y = 1.02; p.x = rand(0, 1); }
    });

    if (Math.random() < dt * 9) {
      const src = Math.random() < 0.6 ? 0.9 : 0.12;
      bubbles.push({ x: W * src + rand(-6, 6), y: H * 0.9, r: rand(1.5, 4.5), vy: rand(50, 95), p: rand(0, TAU) });
    }
    bubbles.forEach((b) => { b.y -= b.vy * dt; b.r += dt * 0.15; });
    bubbles = bubbles.filter((b) => b.y > -10);
  }

  function draw(t) {
    const pal = palette();
    ctx.globalCompositeOperation = 'source-over';
    drawWater(pal, t);
    drawFloor(pal, t);

    // Fish far -> near, hazing everything already drawn between each depth step
    let prevZ = 0;
    fish.forEach((f) => {
      veil(pal, (f.z - prevZ) * 0.42);
      prevZ = f.z;
      const tilt = Math.max(-0.25, Math.min(0.25, Math.atan2(f.vy, Math.max(8, Math.abs(f.flip) * 30)))) * Math.sign(f.flip || 1);
      const sx = Math.sign(f.flip || 1) * Math.max(Math.abs(f.flip), 0.1);
      ctx.save();
      ctx.translate(f.x, f.y);
      ctx.rotate(tilt);
      ctx.scale(sx, 1);
      drawKoi(f);
      ctx.restore();
    });

    // Drifting particles (depth = size + brightness)
    particles.forEach((p) => {
      const s = 0.8 + p.z * 2.2;
      ctx.fillStyle = `rgba(${pal.particle},${0.12 + p.z * 0.35})`;
      ctx.fillRect(p.x * W, p.y * H, s, s);
    });

    // Bubbles
    ctx.lineWidth = 1;
    bubbles.forEach((b) => {
      const x = b.x + Math.sin(t * 3 + b.p) * 4;
      ctx.beginPath();
      ctx.arc(x, b.y, b.r, 0, TAU);
      ctx.fillStyle = `rgba(${pal.bubble},0.14)`;
      ctx.fill();
      ctx.strokeStyle = `rgba(${pal.bubble},0.6)`;
      ctx.stroke();
      ctx.fillStyle = `rgba(${pal.bubble},0.85)`;
      ctx.fillRect(x - b.r * 0.45, b.y - b.r * 0.45, Math.max(1, b.r * 0.35), Math.max(1, b.r * 0.35));
    });

    // Near plants at the side glass
    nearPlants.forEach((p) => drawBlade(p, pal.plantNear, t, H + 4));
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
    update(dt, now / 1000);
    draw(now / 1000);
  }

  function still() {
    update(0, 0);
    draw(0);
  }

  window.addEventListener('resize', () => {
    resize();
    if (reduceMotion) still();
  });

  if (reduceMotion) {
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
