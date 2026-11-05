// Distribute to Stores - splits what a Purchase Order received into one Requested Transfer Order per
// store (sql/supabase_purchase_order_distribution.sql). Shared by Purchase Orders and Posted Purchase
// Orders: PoDistribution.open(poNo, session, { onDone }).
//
// The split, per received item:
//   1. Stores with a shelf level get their need = the Transfer Order request cap (maintain - on hand -
//      on the way), the same number the TO trigger enforces. Short of stock -> shared in proportion to need.
//   2. Whatever is left goes to the stores with NO level, by their share of sales over the sales period.
//   3. Anything still left stays in the warehouse (every store already at its level, or no sales).
// A level that covers all of an item's variants together is shared among those variants by sales.
// Staff can edit every cell before creating; the server re-checks what is left to give out.
(function () {
  let session = null;
  let poNo = '';
  let onDone = null;
  let sources = [];
  let stores = [];
  let sharedGroups = new Map();
  let built = false;

  function esc(value) {
    return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    })[ch]);
  }

  function num(v) {
    const n = Number(v);
    return Number.isFinite(n) ? n : 0;
  }

  function fmt(v) {
    return num(v).toLocaleString(undefined, { maximumFractionDigits: 2 });
  }

  function errText(err, fallback) {
    return err?.message || err?.details || err?.hint || fallback;
  }

  // Whole units summing to floor(total), split by weight (largest remainder).
  function splitByWeight(total, weights) {
    const t = Math.max(0, Math.floor(total));
    const sum = weights.reduce((a, w) => a + Math.max(0, w), 0);
    if (t === 0 || sum <= 0) return weights.map(() => 0);
    const raw = weights.map((w) => (Math.max(0, w) * t) / sum);
    const out = raw.map((r) => Math.floor(r));
    let rem = t - out.reduce((a, b) => a + b, 0);
    const order = raw.map((r, i) => ({ i, f: r - Math.floor(r), w: weights[i] }))
      .sort((a, b) => b.f - a.f || b.w - a.w);
    for (let k = 0; k < order.length && rem > 0; k += 1) {
      if (order[k].w > 0) { out[order[k].i] += 1; rem -= 1; }
    }
    return out;
  }

  function build() {
    if (built) return;
    built = true;
    const wrap = document.createElement('div');
    wrap.id = 'pdistModal';
    wrap.className = 'modal-backdrop hidden pdist-backdrop';
    wrap.innerHTML = `
      <div class="modal-panel pdist-panel" role="dialog" aria-modal="true" aria-labelledby="pdistTitle">
        <div class="pdist-head">
          <div>
            <div class="pdist-caption">PURCHASE ORDER &middot; DISTRIBUTE</div>
            <h2 id="pdistTitle">Distribute to Stores</h2>
            <div class="pdist-sub" id="pdistSub"></div>
          </div>
          <button class="pdist-x" id="pdistXBtn" type="button" title="Close" aria-label="Close">&times;</button>
        </div>
        <div class="pdist-toolbar">
          <label title="Sales used to split stock between stores that have no shelf level">Sales period
            <input type="number" id="pdistSalesDays" min="1" max="365" value="30" /> days</label>
          <button class="btn btn-secondary btn-sm" id="pdistRecalcBtn" type="button">Recalculate</button>
          <button class="btn btn-secondary btn-sm" id="pdistResetBtn" type="button" title="Put back the suggested split, replacing anything typed">Reset split</button>
          <span class="pdist-existing" id="pdistExisting"></span>
        </div>
        <div class="pdist-grid">
          <table class="pdist-table">
            <thead id="pdistHead"></thead>
            <tbody id="pdistBody"></tbody>
          </table>
        </div>
        <div id="pdistError" class="error-text hidden pdist-error"></div>
        <div class="pdist-foot">
          <span class="pdist-hint">Blue = shelf level need &middot; amber = no level, split by sales &middot; red = over the store's level or over what's left.</span>
          <span class="pdist-total" id="pdistTotal"></span>
          <button class="btn btn-secondary" id="pdistCloseBtn" type="button">Cancel</button>
          <button class="btn btn-primary" id="pdistCreateBtn" type="button">Create Transfer Orders</button>
        </div>
      </div>`;
    document.body.appendChild(wrap);

    const close = () => wrap.classList.add('hidden');
    wrap.querySelector('#pdistXBtn').addEventListener('click', close);
    wrap.querySelector('#pdistCloseBtn').addEventListener('click', close);
    wrap.querySelector('#pdistRecalcBtn').addEventListener('click', load);
    wrap.querySelector('#pdistResetBtn').addEventListener('click', () => { allocate(); render(); });
    wrap.querySelector('#pdistCreateBtn').addEventListener('click', create);
    wrap.querySelector('#pdistBody').addEventListener('input', (e) => {
      const input = e.target.closest('.pdist-qty');
      if (!input) return;
      const src = sources[Number(input.dataset.src)];
      const cell = src?.cells.get(input.dataset.store);
      if (!cell) return;
      cell.qty = Math.max(0, Math.floor(num(input.value)));
      refreshChecks();
    });
  }

  function groupRows(rows) {
    const bySource = new Map();
    const storeMap = new Map();
    rows.forEach((r) => {
      const key = `${r.from_wh_id}|${r.item_code}|${r.variant_id || ''}`;
      if (!bySource.has(key)) {
        bySource.set(key, {
          key, from_wh_id: r.from_wh_id, from_wh_name: r.from_wh_name, item_code: r.item_code,
          variant_id: r.variant_id || null, item_name: r.item_name, variant_name: r.variant_name, sku: r.sku,
          received: num(r.received), sent: num(r.sent), wh_on_hand: num(r.wh_on_hand),
          wh_outbound: num(r.wh_outbound), available: Math.floor(num(r.available)), cells: new Map()
        });
      }
      if (!r.store_id || r.store_id === r.from_wh_id) return;
      storeMap.set(r.store_id, r.store_name || r.store_id);
      bySource.get(key).cells.set(r.store_id, {
        store_id: r.store_id, rule: r.rule || null, scope: r.scope, scope_key: r.scope_key,
        maintain: r.maintain, on_hand: num(r.store_on_hand), on_the_way: num(r.on_the_way),
        allowed: r.rule ? Math.floor(num(r.allowed)) : null, sold: num(r.sold_qty),
        need: null, qty: 0, shared: null
      });
    });
    sources = Array.from(bySource.values());
    stores = Array.from(storeMap.entries()).map(([id, name]) => ({ id, name }))
      .sort((a, b) => a.name.localeCompare(b.name));

    // A level shared by several of this PO's lines at one store (an item-wide shelf level on variant
    // lines): split its allowance among them by the store's sales of each, so they can't all claim it.
    sharedGroups = new Map();
    sources.forEach((s) => s.cells.forEach((c) => {
      if (!c.rule || !c.scope_key) return;
      const gk = `${c.store_id}|${c.scope_key}`;
      if (!sharedGroups.has(gk)) sharedGroups.set(gk, { allowed: c.allowed, cells: [] });
      sharedGroups.get(gk).cells.push(c);
    }));
    sharedGroups.forEach((g, gk) => {
      if (g.cells.length < 2) { g.cells[0].need = g.cells[0].allowed; sharedGroups.delete(gk); return; }
      const anySales = g.cells.some((c) => c.sold > 0);
      const parts = splitByWeight(g.allowed, g.cells.map((c) => (anySales ? c.sold : 1)));
      g.cells.forEach((c, i) => { c.need = parts[i]; c.shared = gk; });
    });
  }

  function allocate() {
    sources.forEach((s) => {
      const cells = Array.from(s.cells.values());
      const lev = cells.filter((c) => c.rule);
      const noLev = cells.filter((c) => !c.rule);
      const needTotal = lev.reduce((a, c) => a + num(c.need), 0);
      let left = s.available;
      if (needTotal <= left) {
        lev.forEach((c) => { c.qty = num(c.need); });
        left -= needTotal;
      } else {
        const parts = splitByWeight(left, lev.map((c) => num(c.need)));
        lev.forEach((c, i) => { c.qty = parts[i]; });
        left = 0;
      }
      const parts = splitByWeight(left, noLev.map((c) => c.sold));
      noLev.forEach((c, i) => { c.qty = parts[i]; });
    });
  }

  function cellHtml(s, si, store) {
    const c = s.cells.get(store.id);
    if (!c) return '<td class="pdist-na" title="This warehouse doesn\'t supply this store">-</td>';
    let note;
    let title;
    if (c.rule) {
      note = `need ${fmt(c.need)} &middot; has ${fmt(c.on_hand)}/${fmt(c.maintain)}`;
      title = `${store.name}: ${c.rule}${c.scope === 'item' ? ' (all variants together)' : ''} - maintains ${fmt(c.maintain)}, `
        + `${fmt(c.on_hand)} on hand, ${fmt(c.on_the_way)} on the way -> max ${fmt(c.allowed)}`
        + (c.shared ? `, shared with this PO's other variants (${fmt(c.need)} suggested here)` : '');
    } else {
      note = `sold ${fmt(c.sold)} &middot; has ${fmt(c.on_hand)}`;
      title = `${store.name}: no shelf level - ${fmt(c.sold)} sold in the sales period, ${fmt(c.on_hand)} on hand. Gets a share of what's left by sales.`;
    }
    return `<td class="pdist-cell ${c.rule ? 'is-level' : 'is-sales'}" title="${esc(title)}">
      <input type="number" class="pdist-qty" min="0" step="1" value="${c.qty}" data-src="${si}" data-store="${esc(store.id)}" />
      <small>${note}</small></td>`;
  }

  function render() {
    const head = document.getElementById('pdistHead');
    const body = document.getElementById('pdistBody');
    const multiFrom = new Set(sources.map((s) => s.from_wh_id)).size > 1;
    head.innerHTML = `<tr>
      <th>Item</th>${multiFrom ? '<th>From</th>' : ''}
      <th class="num" title="Received on this PO (base units)">Received</th>
      <th class="num" title="Already on this PO's distribution transfer orders">Sent</th>
      <th class="num" title="Left to give out: received - sent, capped by the warehouse's free stock">Left</th>
      ${stores.map((st) => `<th class="num pdist-store">${esc(st.name)}</th>`).join('')}
      <th class="num" title="Stays in the warehouse">Stays</th></tr>`;

    if (sources.length === 0) {
      body.innerHTML = `<tr><td colspan="${6 + stores.length}" class="pdist-empty">Nothing received on this Purchase Order yet.</td></tr>`;
      refreshChecks();
      return;
    }

    body.innerHTML = sources.map((s, si) => {
      const variant = [s.sku, s.variant_name].filter(Boolean).join(' · ');
      const freeNote = s.available < s.received - s.sent
        ? ` title="Warehouse has ${fmt(s.wh_on_hand)} on hand with ${fmt(s.wh_outbound)} already promised on open TOs"` : '';
      return `<tr data-src="${si}">
        <td class="pdist-item"><b>${esc(s.item_name || s.item_code)}</b><small>${esc(s.item_code)}${variant ? ` &middot; ${esc(variant)}` : ''}</small></td>
        ${multiFrom ? `<td>${esc(s.from_wh_name || '')}</td>` : ''}
        <td class="num">${fmt(s.received)}</td>
        <td class="num">${s.sent ? fmt(s.sent) : '<span class="pdist-zero">0</span>'}</td>
        <td class="num"${freeNote}><b>${fmt(s.available)}</b></td>
        ${stores.map((st) => cellHtml(s, si, st)).join('')}
        <td class="num pdist-stays"></td></tr>`;
    }).join('');
    refreshChecks();
  }

  // Marks over-limit cells, fills the Stays column, and enables Create only when everything fits.
  function refreshChecks() {
    const problems = [];
    const groupSums = new Map();
    sources.forEach((s) => s.cells.forEach((c) => {
      if (c.shared) groupSums.set(c.shared, (groupSums.get(c.shared) || 0) + c.qty);
    }));

    let units = 0;
    const tos = new Set();
    sources.forEach((s, si) => {
      const row = document.querySelector(`#pdistBody tr[data-src="${si}"]`);
      const sum = Array.from(s.cells.values()).reduce((a, c) => a + c.qty, 0);
      const over = sum > s.available;
      if (over) problems.push(`${s.item_name || s.item_code}: ${fmt(sum)} to send, only ${fmt(s.available)} left`);
      if (row) {
        const stays = row.querySelector('.pdist-stays');
        stays.textContent = fmt(s.available - sum);
        stays.classList.toggle('is-bad', over);
      }
      s.cells.forEach((c) => {
        let bad = false;
        if (c.rule) {
          const total = c.shared ? groupSums.get(c.shared) : c.qty;
          if (total > c.allowed) {
            bad = true;
            const st = stores.find((x) => x.id === c.store_id);
            problems.push(`${s.item_name || s.item_code} -> ${st?.name || c.store_id}: over the shelf level (max ${fmt(c.allowed)}${c.shared ? ' across its variants' : ''})`);
          }
        }
        const input = row?.querySelector(`.pdist-qty[data-store="${CSS.escape(c.store_id)}"]`);
        if (input) input.classList.toggle('is-bad', bad || over);
        if (c.qty > 0) { units += c.qty; tos.add(`${s.from_wh_id}|${c.store_id}`); }
      });
    });

    const errorEl = document.getElementById('pdistError');
    const unique = Array.from(new Set(problems));
    errorEl.textContent = unique.join(' · ');
    errorEl.classList.toggle('hidden', unique.length === 0);
    document.getElementById('pdistTotal').textContent = units
      ? `${tos.size} transfer order${tos.size === 1 ? '' : 's'} · ${fmt(units)} unit${units === 1 ? '' : 's'}` : '';
    const btn = document.getElementById('pdistCreateBtn');
    btn.disabled = unique.length > 0 || units === 0;
  }

  async function load() {
    const body = document.getElementById('pdistBody');
    document.getElementById('pdistHead').innerHTML = '';
    body.innerHTML = '<tr><td class="pdist-empty">Calculating...</td></tr>';
    document.getElementById('pdistError').classList.add('hidden');
    const days = parseInt(document.getElementById('pdistSalesDays').value, 10) || 30;

    const { data, error } = await supabaseClient.rpc('staff_get_po_distribution_plan', {
      p_admin_username: session.username,
      p_admin_password: session.password,
      p_po_no: poNo,
      p_sales_days: days
    });
    if (error) {
      body.innerHTML = '';
      const errorEl = document.getElementById('pdistError');
      errorEl.textContent = errText(error, 'Failed to work out the split - run supabase_purchase_order_distribution.sql.');
      errorEl.classList.remove('hidden');
      document.getElementById('pdistCreateBtn').disabled = true;
      return;
    }

    const rows = data || [];
    const docs = rows[0]?.po_transfers;
    document.getElementById('pdistExisting').textContent = docs ? `Already from this PO: ${docs}` : '';
    const fromNames = Array.from(new Set(rows.map((r) => r.from_wh_name).filter(Boolean)));
    groupRows(rows);
    document.getElementById('pdistSub').textContent = stores.length
      ? `${fromNames.join(', ') || 'The warehouse'} -> ${stores.map((s) => s.name).join(', ')}. Shelf level need first, then the rest by sales for stores with no level.`
      : `${fromNames.join(', ') || 'This warehouse'} hasn't sent transfers to any store yet, so there's no store to split to.`;
    allocate();
    render();
  }

  async function create() {
    const lines = [];
    sources.forEach((s) => s.cells.forEach((c) => {
      if (c.qty > 0) {
        lines.push({ from_wh_id: s.from_wh_id, to_wh_id: c.store_id, item_code: s.item_code, variant_id: s.variant_id, qty: c.qty });
      }
    }));
    if (lines.length === 0) return;
    const storeCount = new Set(lines.map((l) => `${l.from_wh_id}|${l.to_wh_id}`)).size;
    if (!window.confirm(`Create ${storeCount} Requested transfer order${storeCount === 1 ? '' : 's'} from ${poNo}?`)) return;

    const btn = document.getElementById('pdistCreateBtn');
    btn.disabled = true;
    const errorEl = document.getElementById('pdistError');
    errorEl.classList.add('hidden');
    try {
      const { data, error } = await supabaseClient.rpc('staff_create_po_distribution_transfers', {
        p_admin_username: session.username,
        p_admin_password: session.password,
        p_po_no: poNo,
        p_lines: lines
      });
      if (error) throw error;
      const made = data || [];
      document.getElementById('pdistHead').innerHTML = '';
      document.getElementById('pdistBody').innerHTML = `<tr><td class="pdist-done">
        <b>Created ${made.length} transfer order${made.length === 1 ? '' : 's'} (Requested):</b>
        <ul>${made.map((m) => `<li><a href="transfer-orders.html?doc=${encodeURIComponent(m.doc_no)}">${esc(m.doc_no)}</a>
          &rarr; ${esc(m.to_warehouse)} &middot; ${m.line_count} line${m.line_count === 1 ? '' : 's'}, ${fmt(m.total_qty)} units</li>`).join('')}</ul>
      </td></tr>`;
      document.getElementById('pdistTotal').textContent = '';
      if (typeof onDone === 'function') onDone(made);
    } catch (err) {
      errorEl.textContent = errText(err, 'Failed to create the transfer orders.');
      errorEl.classList.remove('hidden');
      btn.disabled = false;
    }
  }

  window.PoDistribution = {
    open(no, sess, opts = {}) {
      build();
      poNo = no;
      session = sess;
      onDone = opts.onDone || null;
      document.getElementById('pdistTitle').textContent = `Distribute ${no} to Stores`;
      document.getElementById('pdistSub').textContent = '';
      document.getElementById('pdistExisting').textContent = '';
      document.getElementById('pdistTotal').textContent = '';
      document.getElementById('pdistModal').classList.remove('hidden');
      load();
    }
  };
})();
