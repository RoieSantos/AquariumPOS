// Lets a page that embeds this calculator in an iframe (GMA Conversations' Create Order > Custom
// Aquarium / Custom Stand) read the current quote and "Add to Order" - via postMessage, so it works
// even when the browser treats the iframe as another origin (direct contentWindow access failed
// there with "Can't read the calculator from this page").
//
// Does nothing until the parent sends { type: 'rs-calc-embed-init' }, so the portal's own
// Aquarium/Stand Calculator pages (which also iframe these) are unaffected. After init it hides this
// page's own demo "Add to sale" button + title, then posts a snapshot whenever it changes:
//   { type: 'rs-calc-state', result: lastResult, quote: computeQuotedTotal(lastResult) | null,
//     detailRows: lastDetailRows | null, fields: { id: value | checked },
//     accessories: { light: { code, name, qty } | null, pump: ... } | null }
// Read-only over the pricing script's globals - never calls back into the calculation.
(function () {
  if (window.parent === window) return;

  var FIELD_IDS = [
    'length', 'width', 'height', 'unit', 'option', 'qty', 'stainless', 'paint',
    'sumpHolder', 'sumpWidth',
    'sumpEnabled', 'sumpLength', 'sumpHeight', 'sumpDividerCount', 'sumpDividerHeight', 'sumpDrainValves', 'sumpRaisedChamber', 'sumpTopDrawer',
    'standEnabled', 'standSumpHolder', 'standSumpWidth', 'standPaint', 'standStainless', 'sealant',
    'lowIron', 'highStrip', 'aio', 'enclosure', 'turtleTank', 'aquascape', 'holeCount', 'dividerCount',
    // For the full drawing link (js/calcEmbedLines.js buildAquariumDrawingUrlFrom).
    'filterMedias', 'piping', 'pipingDrain', 'overflowBox', 'allumTopCover',
    'stickerBackground', 'stickerBackgroundType', 'allSides', 'stickerBottom', 'stickerBottomType', 'specialNote'
  ];
  var started = false;
  var lastSent = '';

  function readFields() {
    var fields = {};
    FIELD_IDS.forEach(function (id) {
      var el = document.getElementById(id);
      if (!el) return;
      fields[id] = el.type === 'checkbox' ? Boolean(el.checked) : el.value;
    });
    return fields;
  }

  // The picked submersible light / pump (item code, name, qty) when it's priced into this build - so the
  // order can carry them as their own P0 lines (js/calcEmbedLines.js splitParts). Same "on" rule as the
  // POS's Add to sale in index.html: ticked, priced, and a real item picked.
  function readAccessory(checkId, selectId, qtyId, componentKey, result) {
    var check = document.getElementById(checkId);
    var select = document.getElementById(selectId);
    var cost = result && result.components ? Number(result.components[componentKey]) || 0 : 0;
    if (!check || !check.checked || !select || cost <= 0) return null;
    var code = select.value;
    if (!code || code === '0') return null;
    var opt = select.options[select.selectedIndex];
    var name = opt ? String(opt.textContent || '').replace(/\s+-\s+₱[\d.,]+$/, '').trim() : code;
    var qty = Math.max(1, Math.round(Number((document.getElementById(qtyId) || {}).value) || 1));
    return { code: code, name: name || code, qty: qty };
  }

  function snapshot() {
    var result = typeof lastResult !== 'undefined' ? lastResult : null;
    var quote = null;
    if (result && result.ok && typeof computeQuotedTotal === 'function') {
      try { quote = computeQuotedTotal(result); } catch (e) { quote = null; }
    }
    return {
      type: 'rs-calc-state',
      result: result ? JSON.parse(JSON.stringify(result)) : null,
      quote: quote,
      detailRows: typeof lastDetailRows !== 'undefined' ? lastDetailRows : null,
      fields: readFields(),
      accessories: result && result.ok ? {
        light: readAccessory('submersibleLight', 'lightItemSelect', 'lightQuantity', 'light', result),
        pump: readAccessory('submersiblePump', 'pumpItemSelect', 'pumpQuantity', 'pump', result)
      } : null
    };
  }

  function post() {
    var state;
    try { state = snapshot(); } catch (e) { return; }
    var key = JSON.stringify(state);
    if (key === lastSent) return;
    lastSent = key;
    window.parent.postMessage(state, '*');
  }

  window.addEventListener('message', function (event) {
    if (event.source !== window.parent || !event.data || event.data.type !== 'rs-calc-embed-init') return;
    if (!started) {
      started = true;
      var style = document.createElement('style');
      style.textContent = '#addToSale, .calc-header .title, .calc-header .subtitle { display: none !important; }';
      document.head.appendChild(style);
      setInterval(post, 500);
    }
    lastSent = ''; // parent (re)asked - always answer once
    post();
  });
})();
