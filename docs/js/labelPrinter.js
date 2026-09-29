// Serial barcode labels - shared by Online Orders (Ready to Ship / Print Serial Labels) and Production
// Orders (after Post Output / Print Serial Labels). Per "i have a barcode printer.. so everytime we print
// a barcode it will print on the barcode printer, then for the order printout it will proceed on the
// normal printer".
//
// A web page can't choose a printer, so labels go through QZ Tray (https://qz.io) when it's running on
// this PC: each label is drawn to an image (serial in bold, item code, description, Code128 barcode -
// the desktop's MainForm.DrawSerialNumberLabel layout) and sent straight to General Setup's Barcode
// Printer (PortalSettings BARCODE_PRINTER_NAME) - no dialog. Requests are signed by the qz-sign Edge
// Function against QZ_CERTIFICATE, so QZ Tray prints silently once it trusts that certificate
// (sql/supabase_barcode_printer_settings.sql).
//
// The label LAYOUT is adjustable from General Setup -> Barcode Printer (per "how can we adjust the
// barcode printout?") and saved as JSON in PortalSettings BARCODE_LABEL_LAYOUT: size, offset,
// rotation, text size, which lines show, barcode height, copies. See DEFAULT_LAYOUT.
//
// No QZ Tray / no printer set / it fails -> the browser's print dialog with the same drawn labels, so
// printing never just stops working.
//
// Usage: LabelPrinter.init(session) once, then
//   await LabelPrinter.printSerialLabels([{ serialNo, itemCode, description }])  -> { via, message }
(function () {
  const QZ_SRC = 'https://cdn.jsdelivr.net/npm/qz-tray@2.2.4/qz-tray.js';
  const JSBARCODE_SRC = 'https://cdn.jsdelivr.net/npm/jsbarcode@3.11.6/dist/JsBarcode.all.min.js';
  const PX_PER_MM = 12; // ~300 dpi; QZ Tray scales it onto the label

  const DEFAULT_LAYOUT = {
    widthMm: 100,       // label size
    heightMm: 30,
    offsetXMm: 0,       // shift everything right (+) / left (-)
    offsetYMm: 0,       // shift everything down (+) / up (-)
    rotation: 0,        // 0 / 90 / 180 / 270 - for printers that feed the label sideways / upside down
    textScale: 1,       // 0.8 small, 1 normal, 1.2 large, 1.4 extra large
    showItemCode: true,
    showSku: true,      // "AQ-042 · SKU: ..." (variant SKU, else item SKU - staff_get_serial_skus)
    showDescription: true,
    descriptionLines: 2,
    barcodeHeightPct: 100, // how much of the space left under the text the barcode fills
    barcodeWidthPct: 92,   // barcode width as % of the label width
    copies: 1              // labels per serial
  };

  let session = null;
  let settings = null; // { printer, certificate, layout }
  let securityReady = false;

  const scripts = {};
  function loadScript(src) {
    if (!scripts[src]) {
      scripts[src] = new Promise((resolve, reject) => {
        const el = document.createElement('script');
        el.src = src;
        el.onload = resolve;
        el.onerror = () => { delete scripts[src]; reject(new Error(`Could not load ${src}`)); };
        document.head.appendChild(el);
      });
    }
    return scripts[src];
  }

  async function getSetting(key) {
    const { data, error } = await supabaseClient.rpc('admin_get_public_portal_setting', {
      p_admin_username: session.username,
      p_admin_password: session.password,
      p_setting_key: key
    });
    return error ? '' : (data || '').trim();
  }

  // Saved layout merged over the defaults, every number clamped to something printable.
  function normalizeLayout(raw) {
    let parsed = raw;
    if (typeof raw === 'string') {
      try { parsed = raw ? JSON.parse(raw) : {}; } catch (err) { parsed = {}; }
    }
    const l = { ...DEFAULT_LAYOUT, ...(parsed || {}) };
    const num = (v, min, max, dflt) => {
      const n = Number(v);
      return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : dflt;
    };
    return {
      widthMm: num(l.widthMm, 20, 200, DEFAULT_LAYOUT.widthMm),
      heightMm: num(l.heightMm, 10, 200, DEFAULT_LAYOUT.heightMm),
      offsetXMm: num(l.offsetXMm, -20, 20, 0),
      offsetYMm: num(l.offsetYMm, -20, 20, 0),
      rotation: [0, 90, 180, 270].includes(Number(l.rotation)) ? Number(l.rotation) : 0,
      textScale: num(l.textScale, 0.5, 2, 1),
      showItemCode: l.showItemCode !== false,
      showSku: l.showSku !== false,
      showDescription: l.showDescription !== false,
      descriptionLines: Math.round(num(l.descriptionLines, 1, 4, 2)),
      barcodeHeightPct: num(l.barcodeHeightPct, 30, 100, 100),
      barcodeWidthPct: num(l.barcodeWidthPct, 30, 100, 92),
      copies: Math.round(num(l.copies, 1, 5, 1))
    };
  }

  async function loadSettings(force) {
    if (settings && !force) return settings;
    const [printer, certificate, layout] = await Promise.all([
      getSetting('BARCODE_PRINTER_NAME'), getSetting('QZ_CERTIFICATE'), getSetting('BARCODE_LABEL_LAYOUT')
    ]);
    settings = { printer, certificate, layout: normalizeLayout(layout) };
    return settings;
  }

  // Connects to QZ Tray on this PC (quietly false when it isn't installed / running).
  async function connectQz() {
    try {
      await loadScript(QZ_SRC);
    } catch (err) {
      return false;
    }
    const qz = window.qz;
    if (!securityReady) {
      const { certificate } = await loadSettings();
      qz.security.setCertificatePromise((resolve) => resolve(certificate || null));
      qz.security.setSignatureAlgorithm('SHA512');
      qz.security.setSignaturePromise((toSign) => (resolve, reject) => {
        if (!certificate) { resolve(); return; } // unsigned - QZ Tray will ask "Allow?"
        supabaseClient.functions.invoke('qz-sign', {
          body: { admin_username: session.username, admin_password: session.password, request: toSign }
        }).then(({ data, error }) => {
          if (error || !data?.signature) reject(error || new Error(data?.error || 'qz-sign failed'));
          else resolve(data.signature);
        }).catch(reject);
      });
      securityReady = true;
    }
    if (qz.websocket.isActive()) return true;
    try {
      await qz.websocket.connect({ retries: 0, delay: 0 });
      return true;
    } catch (err) {
      return false;
    }
  }

  // ---- Drawing one label (canvas -> PNG) - used for QZ Tray, the print dialog and the preview.
  function wrapLines(ctx, text, maxWidth, maxLines) {
    const words = String(text || '').split(/\s+/).filter(Boolean);
    const lines = [];
    let line = '';
    for (const word of words) {
      const next = line ? `${line} ${word}` : word;
      if (ctx.measureText(next).width <= maxWidth || !line) { line = next; continue; }
      lines.push(line);
      line = word;
      if (lines.length === maxLines) { line = ''; break; }
    }
    if (line && lines.length < maxLines) lines.push(line);
    return lines;
  }

  async function drawLabel(label, layout) {
    await loadScript(JSBARCODE_SRC);
    const L = layout;
    const mm = (v) => v * PX_PER_MM;
    const W = mm(L.widthMm);
    const H = mm(L.heightMm);
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(W);
    canvas.height = Math.round(H);
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, W, H);
    ctx.translate(mm(L.offsetXMm), mm(L.offsetYMm));
    ctx.fillStyle = '#000';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';

    // Text sizes follow the label height (30mm = the desktop label) and the chosen text size.
    const k = (L.heightMm / 30) * L.textScale;
    const font = (sizeMm, bold) => `${bold ? 'bold ' : ''}${Math.max(8, Math.round(mm(sizeMm * k)))}px Arial, Helvetica, sans-serif`;
    let y = mm(1.5);
    ctx.font = font(3.4, true);
    ctx.fillText(label.serialNo, W / 2, y);
    y += mm(3.9 * k);
    // Item code and SKU share one line to keep the barcode tall: "AQ-042 · SKU: 12345".
    const sku = L.showSku && label.sku && label.sku !== label.itemCode ? `SKU: ${label.sku}` : '';
    const codeLine = [L.showItemCode ? label.itemCode : '', sku].filter(Boolean).join('  ·  ');
    if (codeLine) {
      ctx.font = font(2.6, true);
      let text = codeLine;
      while (text.length > 4 && ctx.measureText(text).width > W - mm(4)) text = text.slice(0, -2);
      ctx.fillText(text === codeLine ? text : `${text}…`, W / 2, y);
      y += mm(3 * k);
    }
    if (L.showDescription && label.description) {
      ctx.font = font(2.3, false);
      wrapLines(ctx, label.description, W - mm(4), L.descriptionLines).forEach((line) => {
        ctx.fillText(line, W / 2, y);
        y += mm(2.6 * k);
      });
    }

    const space = H - y - mm(1.5);
    const bcHeight = space * (L.barcodeHeightPct / 100);
    const bcWidth = W * (L.barcodeWidthPct / 100);
    if (bcHeight > mm(3)) {
      const bc = document.createElement('canvas');
      window.JsBarcode(bc, label.serialNo, { format: 'CODE128', displayValue: false, margin: 0, height: 100, width: 3 });
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(bc, (W - bcWidth) / 2, y + mm(0.5), bcWidth, bcHeight);
    }
    return canvas.toDataURL('image/png');
  }

  async function printViaQz(labels, printer, layout) {
    const qz = window.qz;
    const config = qz.configs.create(printer, {
      size: { width: layout.widthMm, height: layout.heightMm },
      units: 'mm',
      margins: 0,
      scaleContent: true,
      rotation: layout.rotation,
      copies: layout.copies,
      colorType: 'blackwhite',
      interpolation: 'nearest-neighbor'
    });
    const data = [];
    for (const label of labels) {
      const png = await drawLabel(label, layout);
      data.push({ type: 'pixel', format: 'image', flavor: 'base64', data: png.split(',')[1] });
    }
    await qz.print(config, data);
  }

  // ---- Fallback: the browser print dialog - the same drawn labels, one per page at the label size
  // (hidden iframe, so no popup blocker).
  async function printViaDialog(labels, layout) {
    const images = [];
    for (const label of labels) {
      const png = await drawLabel(label, layout);
      for (let c = 0; c < layout.copies; c++) images.push(png);
    }
    document.getElementById('serialLabelFrame')?.remove();
    const frame = document.createElement('iframe');
    frame.id = 'serialLabelFrame';
    frame.setAttribute('aria-hidden', 'true');
    frame.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden;';
    frame.srcdoc = `<!doctype html><html><head><meta charset="utf-8"><title>Serial labels</title><style>
      @page { size: ${layout.widthMm}mm ${layout.heightMm}mm; margin: 0; }
      html, body { margin: 0; padding: 0; background: #fff; }
      img { display: block; width: ${layout.widthMm}mm; height: ${layout.heightMm}mm; break-after: page; page-break-after: always; }
      img:last-child { break-after: auto; page-break-after: auto; }
    </style></head><body>${images.map((src) => `<img src="${src}" alt="">`).join('')}
    <script>window.onload = function () { setTimeout(function () { window.focus(); window.print(); }, 200); };<\/script>
    </body></html>`;
    document.body.appendChild(frame);
  }

  // Fills each label's SKU from the serial (sql/supabase_serial_label_skus.sql) - labels that already
  // carry one keep it. Quietly skipped until that file is run.
  async function attachSkus(list) {
    const missing = list.filter((l) => !l.sku).map((l) => l.serialNo);
    if (!session || !missing.length) return;
    const { data, error } = await supabaseClient.rpc('staff_get_serial_skus', {
      p_admin_username: session.username,
      p_admin_password: session.password,
      p_serial_nos: missing
    });
    if (error) { console.warn('staff_get_serial_skus:', error.message); return; }
    const bySerial = new Map((data || []).map((r) => [r.serial_no, r.sku]));
    list.forEach((l) => { if (!l.sku && bySerial.has(l.serialNo)) l.sku = bySerial.get(l.serialNo); });
  }

  // options.layout - print with this layout instead of the saved one (General Setup's Test Print).
  async function printSerialLabels(labels, options = {}) {
    const list = (labels || []).filter((l) => l && l.serialNo).map((l) => ({ ...l }));
    if (!list.length) return { via: 'none', message: 'No serials to print.' };
    await attachSkus(list);
    if (!session) {
      await printViaDialog(list, normalizeLayout(options.layout || {}));
      return { via: 'dialog', message: 'Opened the print dialog.' };
    }

    const loaded = await loadSettings();
    const layout = options.layout ? normalizeLayout(options.layout) : loaded.layout;
    if (!loaded.printer) {
      await printViaDialog(list, layout);
      return { via: 'dialog', message: 'No Barcode Printer set in General Setup - opened the print dialog instead.' };
    }
    if (!(await connectQz())) {
      await printViaDialog(list, layout);
      return { via: 'dialog', message: 'QZ Tray is not running on this PC - opened the print dialog instead.' };
    }
    try {
      await printViaQz(list, loaded.printer, layout);
      return { via: 'qz', message: `Sent ${list.length} label(s) to ${loaded.printer}.` };
    } catch (err) {
      console.error('QZ Tray print failed:', err);
      await printViaDialog(list, layout);
      return { via: 'dialog', message: `Barcode printer failed (${err?.message || err}) - opened the print dialog instead.` };
    }
  }

  // For General Setup: is QZ Tray reachable here, and which printers does it see.
  async function listPrinters() {
    if (!(await connectQz())) return null;
    return window.qz.printers.find();
  }

  window.LabelPrinter = {
    DEFAULT_LAYOUT,
    init(s) { session = s; },
    reloadSettings() { securityReady = false; return loadSettings(true); },
    async getLayout() { return (await loadSettings()).layout; },
    normalizeLayout,
    // A preview image (data URL) of one label with the given layout.
    preview(label, layout) { return drawLabel(label, normalizeLayout(layout)); },
    printSerialLabels,
    listPrinters,
    isQzAvailable: connectQz
  };
})();
