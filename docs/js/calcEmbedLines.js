// The real calculator pages' posted state -> order lines. Shared by Conversations' Create Order
// (js/gmaConversations.js) and the Advance Order card's Add COD Items (js/onlineOrders.js), so a custom
// build is priced and described the same way on both. Load before either page's script.
// Full build sheet helpers for custom line notes - per "do better details on the note if the order is
// customized.. be specific" (used by the sticker modal below; the aquarium/stand builders take theirs
// straight from the embedded calculator - see calcEmbedNote).
const fmtIn = (v) => `${Number(v).toFixed(2).replace(/\.?0+$/, '')}`;

function customEnteredSizeText(unit, values) {
  if (!unit || unit === 'Inches') return '';
  return ` (entered as ${values.map(fmtIn).join(' x ')} ${unit.toLowerCase()})`;
}

const CALC_TUBULAR_LABELS = { '1x1': '1x1', '1.5x1.5': '1 1/2x1 1/2', '2x2': '2x2' };

// The posted snapshot dressed up as the calculator window the line builders below expect
// (lastResult / computeQuotedTotal / lastDetailRows / document.getElementById(id).value|checked).
function calcEmbedWinFromSnapshot(s) {
  const fields = s.fields || {};
  const doc = {
    getElementById: (id) => {
      if (!(id in fields)) return null;
      return typeof fields[id] === 'boolean' ? { checked: fields[id], value: '' } : { value: fields[id], checked: false };
    }
  };
  return {
    lastResult: s.result,
    computeQuotedTotal: s.quote ? () => s.quote : undefined,
    lastDetailRows: Array.isArray(s.detailRows) ? s.detailRows : [],
    accessories: s.accessories || null,
    document: doc
  };
}

// Calculator component keys (custom-aquarium-calculator.js result.components) of the filtration sump and of
// the tank itself - which line a part's cost rides on (the stand is always its own line).
const CALC_SUMP_COMPONENT_KEYS = ['sumpGlass', 'sumpDividers', 'raisedChamber', 'filterMedia', 'overflowBox', 'light', 'pump',
  'piping', 'allumTopCover', 'topDrawer', 'drainValves', 'sumpStickers'];
const CALC_TANK_COMPONENT_KEYS = ['glass', 'highStrip', 'holes', 'divider', 'stickerBackground', 'stickerBottom', 'aquascapeService'];

// SET-style parts - per "can the options split too? like filter medias / light / pump" + "the sales should
// be revenued too per item": the picked submersible light / pump become their own P0 lines (real item code,
// so stock comes off) under the line whose price includes them (Custom Sump when the sump is its own line,
// else Custom Aquarium). That line keeps the full price, so the order total doesn't change. The lines share
// a bundle_key, and each carries a revenue_weight (its base cost x qty) - the reports split the build's
// revenue by it (sql/supabase_custom_aquarium_part_revenue.sql). No light / pump picked -> lines unchanged.
function splitCalcAccessoryParts(lines, win, r, sumpLineSeparate) {
  const acc = win.accessories || {};
  const comps = r.components || {};
  const cost = (key) => Number(comps[key]) || 0;
  const parts = [['light', 'Submersible light'], ['pump', 'Submersible pump']]
    .filter(([key]) => acc[key] && acc[key].code && cost(key) > 0);
  if (!parts.length) return lines;

  const parent = lines.find((l) => l.category_code === (sumpLineSeparate ? 'CUSTOM-SUMP' : 'CUSTOM-AQUARIUM'));
  if (!parent) return lines;
  const groupKeys = sumpLineSeparate ? CALC_SUMP_COMPONENT_KEYS : CALC_TANK_COMPONENT_KEYS.concat(CALC_SUMP_COMPONENT_KEYS);
  const groupBase = groupKeys.reduce((sum, key) => sum + cost(key), 0);
  const partsBase = parts.reduce((sum, [key]) => sum + cost(key), 0);
  const round2 = (n) => Math.round(n * 100) / 100;
  const bundleKey = `CA-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`;

  parent.bundle_key = bundleKey;
  parent.revenue_weight = round2(Math.max(groupBase - partsBase, 0) * parent.quantity);
  parent.note = `${parent.note}\nIncludes (own P0 lines): ${parts.map(([key]) => `${acc[key].name} x${acc[key].qty}`).join(', ')}`;

  const partLines = parts.map(([key, label]) => ({
    category_code: null,
    item_code: acc[key].code,
    item_name: acc[key].name,
    price: 0,
    quantity: acc[key].qty * parent.quantity,
    note: `${label} - part of ${parent.item_name} (price included in that line)`,
    variation_id: null,
    bundle_key: bundleKey,
    revenue_weight: round2(cost(key) * parent.quantity)
  }));
  const at = lines.indexOf(parent) + 1;
  return lines.slice(0, at).concat(partLines, lines.slice(at));
}

function calcEmbedMissingFields(doc, calcEmbedKind) {
  const num = (id) => Number(doc.getElementById(id)?.value) || 0;
  const checked = (id) => Boolean(doc.getElementById(id)?.checked);
  const missing = [];
  // Sump only (aquarium calculator) hides the tank fields - only the sump's own size matters.
  const sumpOnly = calcEmbedKind !== 'stand' && doc.getElementById('option')?.value === 'Sump only';
  // Sealant colour (aquarium calculator, incl. Sump only) - required, same as the POS's Add to sale.
  const noSealant = calcEmbedKind !== 'stand' && !doc.getElementById('sealant')?.value;
  if (sumpOnly) {
    if (!(num('sumpLength') > 0 && num('sumpWidth') > 0 && num('sumpHeight') > 0)) missing.push('Sump length / width / height');
    if (noSealant) missing.push('Sealant color');
    return missing;
  }
  if (!(num('length') > 0)) missing.push('Length');
  if (!(num('width') > 0)) missing.push('Width');
  if (calcEmbedKind !== 'stand' && !(num('height') > 0)) missing.push('Height');
  if (!doc.getElementById('unit')?.value) missing.push('Unit of measure');
  if (calcEmbedKind === 'stand') {
    if (checked('sumpHolder') && !(num('sumpWidth') > 0)) missing.push('Sump Holder width');
    if (!checked('stainless') && !doc.getElementById('paint')?.value) missing.push('Paint color');
  } else {
    if (noSealant) missing.push('Sealant color');
    if (checked('sumpEnabled') && !(num('sumpLength') > 0 && num('sumpWidth') > 0 && num('sumpHeight') > 0)) missing.push('Sump length / width / height');
    if (checked('standEnabled') && checked('standSumpHolder') && !(num('standSumpWidth') > 0)) missing.push('Stand Sump Holder width');
    if (checked('standEnabled') && !checked('standStainless') && !doc.getElementById('standPaint')?.value) missing.push('Stand paint color');
  }
  return missing;
}

// lastDetailRows (index.html's Details summary) -> "Label: value" build-sheet lines, minus the price
// rows (makers read this note; prices are already on the line itself).
function calcDetailRowsText(rows, filter) {
  return rows
    .filter(([label]) => !/Price|^↳|^Total/.test(label) && filter(label))
    .map(([label, value]) => (/^(Hole for Aquarium|Divider)/.test(label) ? label : `${label}: ${value}`));
}

function buildAquariumDrawingUrlFrom(n, highStrip) {
  const params = new URLSearchParams({
    length: String(n.lengthInches),
    width: String(n.widthInches),
    height: String(n.heightInches),
    unit: 'Inches',
    glass: String(n.glassThickness)
  });
  if (n.temperedGlass) params.set('tempered', '1');
  if (n.rimless) params.set('rimless', '1');
  if (highStrip) params.set('highStrip', '1');
  if (n.stand) {
    params.set('standEnabled', '1');
    params.set('standLayers', String(n.stand.layers));
    params.set('standTubular', String(n.stand.tubular));
    if (n.stand.stainless) params.set('standStainless', '1');
  }
  return `https://rspetstop.com/WebAquariumCalculator/index.html?${params.toString()}`;
}

// opts.splitParts: the light / pump as their own P0 lines (splitCalcAccessoryParts) - Conversations' Add
// to Order only; Put in reply, Add COD Items and the customer calculator keep one line per part group.
function buildAquariumCalcLines(win, opts = {}) {
  const r = win.lastResult;
  if (!r || !r.ok || typeof win.computeQuotedTotal !== 'function') return [];
  const n = r.normalized;
  const doc = win.document;
  const checked = (id) => Boolean(doc.getElementById(id)?.checked);
  const val = (id) => doc.getElementById(id)?.value || '';
  const q = win.computeQuotedTotal(r);
  const rows = Array.isArray(win.lastDetailRows) ? win.lastDetailRows : [];

  // "Sump only" Build type - no aquarium, so the whole quote is one CUSTOM-SUMP line.
  if (r.sumpOnly) {
    const so = n.sumpOnly || {};
    const sumpOnlyLines = [{
      category_code: 'CUSTOM-SUMP',
      item_code: null,
      item_name: `Custom ${so.type} Sump (${fmtIn(n.lengthInches)}x${fmtIn(n.widthInches)}x${fmtIn(n.heightInches)}in)`,
      price: Math.round(q.sumpUnitPrice * 100) / 100,
      quantity: q.sumpQty,
      note: ['CUSTOM SUMP / FILTRATION', 'Sump only - no aquarium']
        .concat(calcDetailRowsText(rows, (label) => label !== 'Build type'))
        .join('\n'),
      variation_id: null
    }];
    return opts.splitParts ? splitCalcAccessoryParts(sumpOnlyLines, win, r, true) : sumpOnlyLines;
  }

  const sumpSeparate = q.sumpEnabled && q.sumpUnitPrice > 0;
  const standSeparate = q.standEnabled && q.standUnitPrice > 0;
  const size = `${fmtIn(n.lengthInches)} x ${fmtIn(n.widthInches)} x ${fmtIn(n.heightInches)} in`;
  const isSumpRow = (label) => /^(Filtration Sump|Sump )/.test(label);
  const isStandRow = (label) => /^Stand/.test(label);

  const bits = [`${fmtIn(n.lengthInches)}x${fmtIn(n.widthInches)}x${fmtIn(n.heightInches)}in`, n.glassThickness];
  if (n.option && n.option !== 'Aquarium only') bits.unshift(n.option);
  if (n.temperedGlass) bits.push('Tempered');
  if (checked('lowIron')) bits.push('Low-Iron');
  if (n.panelGlassText) bits.push(`Mixed Glass (${n.panelGlassText})`);
  if (n.rimless) bits.push('Rimless');
  if (checked('highStrip')) bits.push('High Strip');
  if (checked('aio')) bits.push('AIO');
  if (checked('enclosure')) bits.push('Enclosure');
  if (checked('turtleTank')) bits.push('Turtle Tank');
  if (checked('aquascape')) bits.push('Aquascape Service');
  if (Number(val('holeCount')) > 0) bits.push(`${val('holeCount')} Hole(s)`);
  if (Number(val('dividerCount')) > 0) bits.push(`${val('dividerCount')} Divider(s)`);
  if (n.sump && !sumpSeparate) bits.push(`${n.sump.type} Filtration`);

  const drawingUrl = buildAquariumDrawingUrlFrom(n, checked('highStrip'));
  const aquariumNote = ['CUSTOM AQUARIUM']
    .concat(calcDetailRowsText(rows, (label) => !isStandRow(label) && !(sumpSeparate && isSumpRow(label))))
    .concat(standSeparate ? ['Stand: Yes - see Custom Stand line'] : ['Stand: None (aquarium only)'])
    .concat(sumpSeparate ? ['Filtration: see Custom Sump line'] : [])
    .concat([`Drawing: ${drawingUrl}`]);

  const lines = [{
    category_code: 'CUSTOM-AQUARIUM',
    item_code: null,
    item_name: `Custom Aquarium (${bits.join(', ')})`,
    price: Math.round(q.perAquariumTotal * 100) / 100,
    quantity: q.aquariumQty,
    note: aquariumNote.join('\n'),
    variation_id: null
  }];

  if (standSeparate) {
    const s = n.stand;
    const standBits = [`${s.layers}-Layer ${CALC_TUBULAR_LABELS[s.tubular] || s.tubular} Tubular${s.stainless ? ' (Stainless)' : ''}`, `${fmtIn(s.heightInches)}in height`];
    // Black / White paint from the aquarium calculator's stand step (spec only) - not for stainless.
    const standPaint = s.stainless ? '' : val('standPaint');
    if (standPaint) standBits.push(`${standPaint} Paint`);
    if (s.cabinet) standBits.push('Cabinet');
    if (s.canopy) standBits.push('Canopy');
    if (s.sumpHolder) standBits.push(`Sump Holder (${fmtIn(s.sumpWidth)}in)`);
    lines.push({
      category_code: 'CUSTOM-STAND',
      item_code: null,
      item_name: `Custom Stand (${standBits.join(', ')})`,
      price: Math.round(q.standUnitPrice * 100) / 100,
      quantity: q.standQty,
      note: ['CUSTOM STAND', `For aquarium: ${size} (stand top = ${fmtIn(n.lengthInches)} x ${fmtIn(n.widthInches)} in)`]
        .concat(calcDetailRowsText(rows, isStandRow))
        .concat([`Drawing: ${drawingUrl}`])
        .join('\n'),
      variation_id: null
    });
  }

  if (sumpSeparate) {
    const sp = n.sump;
    lines.push({
      category_code: 'CUSTOM-SUMP',
      item_code: null,
      item_name: `Custom ${sp.type} Sump (${fmtIn(sp.lengthInches)}x${fmtIn(sp.widthInches)}x${fmtIn(sp.heightInches)}in)`,
      price: Math.round(q.sumpUnitPrice * 100) / 100,
      quantity: q.sumpQty,
      note: ['CUSTOM SUMP / FILTRATION', `For aquarium: ${size}`]
        .concat(calcDetailRowsText(rows, isSumpRow))
        .join('\n'),
      variation_id: null
    });
  }

  return opts.splitParts ? splitCalcAccessoryParts(lines, win, r, sumpSeparate) : lines;
}

function buildStandCalcLines(win) {
  const r = win.lastResult;
  if (!r || !r.ok) return [];
  const n = r.normalized;
  const doc = win.document;
  const qty = Math.max(1, Math.round(Number(doc.getElementById('qty')?.value) || 1));
  const tubular = CALC_TUBULAR_LABELS[n.tubular] || n.tubular;
  // Black / White paint from the stand calculator (spec only, no price) - not for stainless.
  const paint = n.stainless ? '' : (doc.getElementById('paint')?.value || '');

  const bits = [`${fmtIn(n.lengthInches)}x${fmtIn(n.widthInches)}x${fmtIn(n.heightInches)}in`, `${n.layers}-Layer ${tubular} Tubular${n.stainless ? ' (Stainless)' : ''}`];
  if (paint) bits.push(`${paint} Paint`);
  if (n.cabinet) bits.push('Cabinet');
  if (n.canopy) bits.push('Canopy');
  if (n.sumpHolder) bits.push(`Sump Holder (${fmtIn(n.sumpWidthInches)}in)`);

  const params = new URLSearchParams({
    length: String(n.lengthInches),
    width: String(n.widthInches),
    height: String(n.heightInches),
    unit: 'Inches',
    layers: String(n.layers),
    tubular: String(n.tubular)
  });
  if (n.stainless) params.set('stainless', '1');

  const note = [
    'CUSTOM STAND (stand only - no aquarium)',
    `Top size (L x W): ${fmtIn(n.lengthInches)} x ${fmtIn(n.widthInches)} in`
      + customEnteredSizeText(n.unit, [doc.getElementById('length')?.value, doc.getElementById('width')?.value]),
    `Frame: ${n.layers}-layer, ${tubular} in tubular, ${n.stainless ? 'Stainless steel' : `Standard steel, ${paint ? `${paint.toUpperCase()} PAINT` : 'painted'}`}`,
    `Height: ${fmtIn(n.heightInches)} in total floor-to-top${Number(n.footingInches) > 0 ? ` (includes ${fmtIn(n.footingInches)} in footing)` : ''}`,
    `Cabinet: ${n.cabinet ? `Yes - ${n.cabinetType || ''} ${n.cabinetDoors ? `${n.cabinetDoors} doors` : ''}`.trim() : 'No (open frame)'}`,
    `Canopy: ${n.canopy ? `Yes${n.canopyHeightInches ? ` - ${fmtIn(n.canopyHeightInches)} in high` : ''}` : 'No'}`,
    `Sump Holder: ${n.sumpHolder ? `Yes - ${fmtIn(n.sumpWidthInches)} in wide` : 'No'}`
  ];
  if (r.notice) note.push(`Note: ${r.notice.title} - ${r.notice.message}`);
  note.push(`Drawing: https://rspetstop.com/WebAquariumCalculator/stand.html?${params.toString()}`);

  return [{
    category_code: 'CUSTOM-STAND',
    item_code: null,
    item_name: `Custom Stand (${bits.join(', ')})`,
    price: Math.round(r.totalPrice * 100) / 100,
    quantity: qty,
    note: note.join('\n'),
    variation_id: null
  }];
}
