// Stock FactBox - on-hand per warehouse for each line of a document, per "can we show in the factbox in
// the right if there is available stocks per item? so the user can see if there are no stocks or have?".
// Used by the Online / Walk-in and Advance Order cards (onlineOrders.js), Transfer Orders and Purchase
// Orders. One call for all lines: staff_get_lines_stock_by_warehouse (sql/supabase_lines_stock_by_warehouse.sql)
// - Item Ledger for regular items, IN_STOCK serials for Aquarium / Stand / Sump (same as Alice); serials
// RESERVED for an order are shown apart as "n reserved".
//
// Markup (the page owns it):
//   <aside class="oc-factbox" id="...">
//     <div class="oc-fact-title">Stock <span class="muted" data-isf-count></span></div>
//     <div class="oc-fact-body" data-isf-body></div>
//   </aside>
// ItemStockFactbox.load(box, lines) - lines: [{ item_code, variant_id, label, warehouse, warehouseName }];
// warehouse is the ID or name the line is for (its quantity becomes the badge), else the badge is the
// total. warehouseName labels it when that warehouse has no row (not a stock warehouse, nothing there).
// ItemStockFactbox.loadDocument(box, docType, docNo, warehouseName) - same, for a list's selected row
// (lines read server-side).
// ItemStockFactbox.wireListRows(tbody, box, docType, open) - list click = select + stock, No. / dblclick = open.
// ItemStockFactbox.setAssigned(box, docKey, serialRows) - the document's linked serials ({ item_code }); an
// item that already has one shows "Serial assigned to this order" instead of its stock badge, and isn't
// counted as out. Matched by docKey (load's 3rd / loadDocument's docNo), so it can arrive before or after.
// ItemStockFactbox.clear(box, text) - placeholder while a document loads / has no lines.
(function () {
  function esc(value) {
    return String(value ?? '')
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function fmtQty(n) {
    const v = Number(n) || 0;
    return Number.isInteger(v) ? String(v) : v.toFixed(2).replace(/\.?0+$/, '');
  }

  function parts(box) {
    return { body: box.querySelector('[data-isf-body]'), count: box.querySelector('[data-isf-count]') };
  }

  function clear(box, text) {
    if (!box) return;
    box._isfToken = (box._isfToken || 0) + 1; // drop any load still in flight
    const { body, count } = parts(box);
    body.innerHTML = `<p class="oc-fact-empty muted">${esc(text || 'No items.')}</p>`;
    if (count) count.textContent = '';
  }

  function sameWarehouse(row, wh) {
    const w = String(wh || '').trim().toLowerCase();
    return !!w && (String(row.warehouse_id || '').toLowerCase() === w || String(row.warehouse_name || '').trim().toLowerCase() === w);
  }

  async function load(box, lines, docKey) {
    if (!box) return;
    box._isfDoc = docKey == null ? null : String(docKey);
    // One entry per item + variant + warehouse - the same item on two lines is shown once.
    const unique = new Map();
    (lines || []).forEach((l) => {
      const item = String(l.item_code || '').trim();
      if (!item) return;
      const key = [item, l.variant_id || '', l.warehouse || ''].join('|');
      if (!unique.has(key)) unique.set(key, { ...l, key, item_code: item });
    });
    const list = [...unique.values()];
    if (!list.length) { clear(box, 'No items on this document.'); return; }

    const token = (box._isfToken || 0) + 1;
    box._isfToken = token;
    const { body, count } = parts(box);
    body.innerHTML = '<p class="oc-fact-empty muted">Loading stock...</p>';
    if (count) count.textContent = '';

    const { data, error } = await supabaseClient.rpc('staff_get_lines_stock_by_warehouse', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_lines: list.map((l) => ({ key: l.key, item_code: l.item_code, variant_id: l.variant_id || null }))
    });
    if (box._isfToken !== token) return; // another document opened meanwhile
    render(box, list, data, error, 'supabase_lines_stock_by_warehouse.sql');
  }

  // List FactBox: the selected row's document - the server reads its lines (a list row doesn't carry
  // them). docType: 'online' | 'advance' | 'transfer' | 'purchase' (staff_get_document_stock_by_warehouse).
  async function loadDocument(box, docType, docNo, warehouseName) {
    if (!box) return;
    if (!docNo) { clear(box, 'Select a row to see its stock.'); return; }
    box._isfDoc = String(docNo);
    const token = (box._isfToken || 0) + 1;
    box._isfToken = token;
    const { body, count } = parts(box);
    body.innerHTML = '<p class="oc-fact-empty muted">Loading stock...</p>';
    if (count) count.textContent = '';

    const { data, error } = await supabaseClient.rpc('staff_get_document_stock_by_warehouse', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_doc_type: docType,
      p_doc_no: String(docNo)
    });
    if (box._isfToken !== token) return; // another row picked meanwhile

    const list = [];
    const seen = new Set();
    (data || []).forEach((r) => {
      if (seen.has(r.line_key)) return;
      seen.add(r.line_key);
      list.push({ key: r.line_key, item_code: r.item_code, label: r.label, warehouse: r.doc_warehouse, warehouseName });
    });
    render(box, list, data, error, 'supabase_document_stock_by_warehouse.sql');
  }

  // The badge's place name - never a raw warehouse UUID (an order's LocationID that isn't a stock warehouse).
  function placeName(here, l) {
    if (here) return here.warehouse_name;
    if (l.warehouseName) return l.warehouseName;
    return /^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(String(l.warehouse)) ? 'this branch' : l.warehouse;
  }

  function setAssigned(box, docKey, serialRows) {
    if (!box) return;
    const counts = new Map();
    (serialRows || []).forEach((s) => {
      const code = String(s.item_code || '').trim().toUpperCase();
      if (code) counts.set(code, (counts.get(code) || 0) + 1);
    });
    box._isfAssigned = { doc: String(docKey), counts };
    const last = box._isfLast;
    if (last && box._isfDoc === String(docKey)) render(box, last.list, last.data, last.error, last.sqlFile);
  }

  function assignedCount(box, itemCode) {
    const a = box._isfAssigned;
    if (!a || a.doc !== box._isfDoc) return 0;
    return a.counts.get(String(itemCode || '').trim().toUpperCase()) || 0;
  }

  function render(box, list, data, error, sqlFile) {
    box._isfLast = { list, data, error, sqlFile }; // re-drawn by setAssigned when the serials arrive
    const { body, count } = parts(box);
    if (error) {
      body.innerHTML = `<p class="oc-fact-empty muted">${/schema cache|could not find the function|does not exist/i.test(error.message)
        ? `Stock lookup isn't set up yet - run sql/${sqlFile}.`
        : `Could not load stock: ${esc(error.message)}`}</p>`;
      return;
    }

    const rowsByKey = new Map();
    (data || []).forEach((r) => {
      if (!rowsByKey.has(r.line_key)) rowsByKey.set(r.line_key, []);
      rowsByKey.get(r.line_key).push(r);
    });

    let outCount = 0;
    let notStock = 0;
    const html = list.map((l) => {
      const rows = rowsByKey.get(l.key);
      if (!rows) { notStock++; return ''; }
      const here = l.warehouse ? rows.find((r) => sameWarehouse(r, l.warehouse)) : null;
      const hereName = placeName(here, l);
      const qty = l.warehouse ? (here ? Number(here.quantity) || 0 : 0) : rows.reduce((s, r) => s + (Number(r.quantity) || 0), 0);
      // Serials already tagged to this order - its stock doesn't matter any more.
      const assigned = assignedCount(box, l.item_code);
      if (qty <= 0 && !assigned) outCount++;
      // Reserved = serials held for an order (sql/supabase_serial_order_reservation.sql) - on the shelf but
      // not for sale, so not in the quantity.
      const reserved = l.warehouse ? (here ? Number(here.reserved) || 0 : 0) : rows.reduce((s, r) => s + (Number(r.reserved) || 0), 0);
      const reservedBadge = reserved > 0
        ? `<span class="badge badge-warning" title="Held for an order - can't be sold to anyone else">${fmtQty(reserved)} reserved</span>` : '';
      const badge = assigned
        ? `<span class="badge badge-primary" title="Serials linked to this order - see Serials below">&#10003; ${assigned === 1 ? 'Serial' : `${assigned} serials`} assigned to this order</span>`
        : (qty > 0
        ? `<span class="badge badge-success">${fmtQty(qty)}${l.warehouse ? ` at ${esc(hereName)}` : ' in stock'}</span>`
        : `<span class="badge badge-danger">No stock${l.warehouse ? ` at ${esc(hereName)}` : ''}</span>`) + reservedBadge;
      const others = rows
        .filter((r) => (assigned || r !== here) && ((Number(r.quantity) || 0) !== 0 || (Number(r.reserved) || 0) !== 0 || r.is_stock_warehouse))
        .map((r) => `<span class="isf-loc${(Number(r.quantity) || 0) > 0 ? ' isf-has' : ''}"${(Number(r.reserved) || 0) > 0 ? ` title="+${fmtQty(r.reserved)} reserved"` : ''}>${esc(r.warehouse_name)} <b>${fmtQty(r.quantity)}</b></span>`)
        .join('');
      const src = rows[0].source === 'serials' ? 'Counted from IN_STOCK serials' : 'From the Item Ledger';
      return `<li class="isf-item ${assigned ? 'isf-assigned' : qty > 0 ? 'isf-in' : 'isf-none'}" title="${src}">
        <div class="isf-code">${esc(l.item_code)}</div>
        ${l.label && l.label !== l.item_code ? `<div class="isf-desc muted" title="${esc(l.label)}">${esc(l.label)}</div>` : ''}
        <div class="isf-badges">${badge}</div>
        ${others ? `<div class="isf-locs">${l.warehouse ? `<span class="isf-locs-label muted">${assigned ? 'Stock' : 'Elsewhere'}</span>` : ''}${others}</div>` : ''}
      </li>`;
    }).join('');

    body.innerHTML = (html ? `<ul class="isf-list">${html}</ul>` : '<p class="oc-fact-empty muted">No stock items on this document.</p>')
      + (notStock && html ? `<p class="isf-note muted">${notStock} line${notStock === 1 ? '' : 's'} not a stock item (custom / service).</p>` : '');
    if (count) count.textContent = outCount ? `(${outCount} out)` : '';
    if (count) count.classList.toggle('isf-out', outCount > 0);
  }

  // Transfer / Purchase Order lists (BC-style like the Online Orders list): clicking a row selects it and
  // shows its stock; its No. or a double-click opens it. While the FactBox is hidden (narrow screen) a
  // click opens straight away, as before. Rows carry data-doc-key = the document no.
  function wireListRows(tbody, box, docType, open) {
    tbody.querySelectorAll('tr[data-doc-key]').forEach((row) => {
      const docNo = row.dataset.docKey;
      row.classList.toggle('selected', box?.dataset.selectedDoc === docNo);
      row.addEventListener('dblclick', () => open(docNo));
      row.addEventListener('click', (e) => {
        if (!box || !box.offsetParent || e.target.closest('.bc-doc-no')) { open(docNo); return; }
        tbody.querySelectorAll('tr.selected').forEach((tr) => tr.classList.remove('selected'));
        row.classList.add('selected');
        if (box.dataset.selectedDoc === docNo) return;
        box.dataset.selectedDoc = docNo;
        clearTimeout(box._isfSelTimer);
        box._isfSelTimer = setTimeout(() => loadDocument(box, docType, docNo), 250);
      });
    });
    // the selected document scrolled/filtered out of the list - empty the FactBox
    if (box && box.dataset.selectedDoc && !tbody.querySelector('tr.selected')) {
      delete box.dataset.selectedDoc;
      clear(box, 'Select a row to see its stock.');
    }
  }

  window.ItemStockFactbox = { load, loadDocument, setAssigned, clear, wireListRows };
})();
