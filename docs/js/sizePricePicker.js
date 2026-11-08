// Size-based pricing picker (sql/supabase_item_size_pricing.sql) - shared by Conversations Create
// Order, the Online Orders New tab and Online Orders "Add Item". For a product on a Size Scale (e.g.
// SHBRTG: Standard 8,500 / 10-11" 10,000) staff pick the size and the price is worked out by the
// scale's formula - no typing. Stock is unchanged (same product / variant); only the price and the
// line name ("SHBRTG - Size 10-11"") change.
//
// pickSizePrice({ itemCode, itemName, basePrice }) resolves to:
//   null                      - the product is not size-priced (or the lookup failed): add it as usual
//   false                     - staff closed the picker: don't add anything
//   { label: null, price }    - Standard size (the normal price)
//   { label: '10-11"', price } - a size tier
(function () {
  const cache = new Map(); // itemCode|base -> rpc result (null = not size-priced)

  function esc(v) {
    return (v ?? '').toString().replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function peso(n) {
    return '&#8369;' + Number(n || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  async function fetchSizePrices(itemCode, basePrice) {
    if (!itemCode) return null;
    const key = `${itemCode}|${basePrice ?? ''}`;
    if (cache.has(key)) return cache.get(key);
    const { data, error } = await supabaseClient.rpc('public_get_item_size_prices', {
      p_item_code: itemCode,
      p_base_price: basePrice ?? null
    });
    if (error) {
      // Not set up yet (SQL not run) or offline - never block a sale over it.
      console.warn('Size prices unavailable:', error.message);
      return null;
    }
    const result = data && Array.isArray(data.tiers) && data.tiers.length ? data : null;
    cache.set(key, result);
    return result;
  }

  // Line name for a picked size - "SHBRTG - Size 10-11"". Standard keeps the plain name.
  function sizeLineName(name, label) {
    return label ? `${name} - Size ${label}` : name;
  }

  function showPicker(itemName, sizeData) {
    return new Promise((resolve) => {
      const backdrop = document.createElement('div');
      backdrop.className = 'modal-backdrop';
      backdrop.style.zIndex = '1300'; // above the bc-dialogs (200) and confirm dialog (1200)
      const rows = [{ label: null, price: sizeData.base_price }, ...sizeData.tiers];
      backdrop.innerHTML = `
        <div class="modal-panel" role="dialog" aria-modal="true" style="max-width:420px;">
          <div class="toolbar">
            <h2 style="margin:0;">Choose the Size</h2>
            <button class="btn btn-secondary btn-sm" type="button" data-close style="margin-left:auto;">Close</button>
          </div>
          <p class="muted" style="margin:6px 0 12px;">${esc(itemName)} is priced by size${sizeData.scale_name ? ` (${esc(sizeData.scale_name)})` : ''}.</p>
          <div style="display:flex; flex-direction:column; gap:8px;">
            ${rows.map((r, i) => `
              <button class="btn ${i === 0 ? 'btn-secondary' : 'btn-primary'}" type="button" data-index="${i}"
                style="display:flex; justify-content:space-between; align-items:center; width:100%; text-align:left;">
                <span>${r.label ? `Size ${esc(r.label)}` : 'Standard size'}</span>
                <b>${peso(r.price)}</b>
              </button>`).join('')}
          </div>
        </div>`;
      const done = (value) => {
        backdrop.remove();
        document.removeEventListener('keydown', onKey);
        resolve(value);
      };
      const onKey = (e) => { if (e.key === 'Escape') done(false); };
      backdrop.addEventListener('click', (e) => {
        if (e.target === backdrop || e.target.closest('[data-close]')) return done(false);
        const btn = e.target.closest('[data-index]');
        if (!btn) return;
        const r = rows[Number(btn.dataset.index)];
        done({ label: r.label || null, price: Number(r.price) });
      });
      document.addEventListener('keydown', onKey);
      document.body.appendChild(backdrop);
      backdrop.querySelector('[data-index]')?.focus();
    });
  }

  async function pickSizePrice({ itemCode, itemName, basePrice }) {
    const sizeData = await fetchSizePrices(itemCode, basePrice);
    if (!sizeData) return null;
    return showPicker(itemName || itemCode, sizeData);
  }

  window.pickSizePrice = pickSizePrice;
  window.sizeLineName = sizeLineName;
})();
