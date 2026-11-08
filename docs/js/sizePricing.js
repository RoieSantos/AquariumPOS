// Size Pricing page (super users) - sql/supabase_item_size_pricing.sql. Each size scale is a formula
// (per size: +% and/or +₱ on the product's normal price, rounded to the scale's Round To) and the
// products that use it. The sale screens ask for the size (js/sizePricePicker.js, desktop POS).
let currentSession = null;
let scales = [];

function esc(v) {
  return (v ?? '').toString().replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function peso(n) {
  return '&#8369;' + Number(n || 0).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

// Same formula as public._size_tier_price.
function tierPrice(base, pct, amount, roundTo) {
  const raw = Number(base || 0) * (1 + Number(pct || 0) / 100) + Number(amount || 0);
  const step = Number(roundTo || 0);
  const price = step > 0 ? Math.round(raw / step) * step : Math.round(raw * 100) / 100;
  return Math.max(Number(base || 0), price);
}

function rpcArgs(extra) {
  return { p_admin_username: currentSession.username, p_admin_password: currentSession.password, ...extra };
}

async function loadScales() {
  const box = document.getElementById('scalesBox');
  const { data, error } = await supabaseClient.rpc('admin_list_size_scales', rpcArgs({}));
  if (error) {
    box.innerHTML = `<p class="error-text">${esc(/could not find the function|schema cache/i.test(error.message)
      ? 'Size pricing isn\'t set up in the database yet - run sql/supabase_item_size_pricing.sql.' : error.message)}</p>`;
    return;
  }
  scales = data || [];
  renderScales();
}

function renderScales() {
  const box = document.getElementById('scalesBox');
  if (scales.length === 0) {
    box.innerHTML = '<p class="muted">No size scales yet. Click + New Size Scale, e.g. "Large Fish" with sizes 10-11" (+18%) and 12"+ (+40%).</p>';
    return;
  }
  box.innerHTML = scales.map((s, si) => scaleHtml(s, si)).join('');
}

function tierRowHtml(t) {
  return `
    <tr>
      <td><input type="text" class="sp-label" value="${esc(t.label)}" placeholder='e.g. 10-11"' /></td>
      <td><input type="number" class="sp-pct" min="0" step="0.01" value="${t.markup_percent ? Number(t.markup_percent) : ''}" placeholder="0" /></td>
      <td><input type="number" class="sp-amt" min="0" step="1" value="${t.markup_amount ? Number(t.markup_amount) : ''}" placeholder="0" /></td>
      <td><button class="btn btn-secondary btn-sm" type="button" data-action="remove-tier">Remove</button></td>
    </tr>`;
}

function itemPricesHtml(s, item) {
  return s.tiers.map((t) => `${esc(t.label)} ${peso(tierPrice(item.price, t.markup_percent, t.markup_amount, s.round_to))}`).join(' &middot; ');
}

function scaleHtml(s, si) {
  const isNew = !!s.is_new;
  return `
    <div class="sp-scale" data-index="${si}">
      <div class="sp-head">
        <label>Code<input type="text" class="sp-code" value="${esc(s.code)}" ${isNew ? '' : 'readonly'} placeholder="LARGEFISH" style="max-width:150px;" /></label>
        <label style="flex:1; min-width:180px;">Name<input type="text" class="sp-name" value="${esc(s.name)}" placeholder="Large Fish" /></label>
        <label>Round to (&#8369;)<input type="number" class="sp-round" min="0" step="1" value="${Number(s.round_to ?? 100)}" style="max-width:110px;" /></label>
        <button class="btn btn-success btn-sm" type="button" data-action="save">Save</button>
        ${isNew ? '' : '<button class="btn btn-secondary btn-sm" type="button" data-action="delete">Delete</button>'}
      </div>
      <div class="table-wrap" style="margin-top:12px;">
        <table class="sp-tiers">
          <thead><tr><th>Size</th><th>+ %</th><th>+ &#8369;</th><th></th></tr></thead>
          <tbody>${(s.tiers.length ? s.tiers : [{ label: '', markup_percent: '', markup_amount: '' }]).map(tierRowHtml).join('')}</tbody>
        </table>
      </div>
      <button class="btn btn-secondary btn-sm" type="button" data-action="add-tier" style="margin-top:8px;">+ Add Size</button>
      <p class="muted" style="margin:8px 0 0;">The smallest size is always the product's normal price ("Standard size"). Only list the bigger sizes here.</p>
      ${isNew ? '<p class="muted">Save the scale first, then add products to it.</p>' : `
      <div class="sp-items">
        <h3 style="margin:12px 0 6px;">Products on this scale (${s.items.length})</h3>
        <div class="sp-search-wrap">
          <input type="text" class="sp-search" placeholder="Add a product - search name or code" autocomplete="off" style="width:100%;" />
          <div class="sp-search-results hidden"></div>
        </div>
        <div class="table-wrap" style="margin-top:8px;">
          <table>
            <thead><tr><th>Product</th><th>Standard</th><th>Size prices</th><th></th></tr></thead>
            <tbody>${s.items.length ? s.items.map((it) => `
              <tr>
                <td>${esc(it.name)} <span class="muted">${esc(it.code)}</span></td>
                <td>${peso(it.price)}</td>
                <td class="sp-prices">${itemPricesHtml(s, it)}</td>
                <td><button class="btn btn-secondary btn-sm" type="button" data-action="unassign" data-code="${esc(it.code)}">Remove</button></td>
              </tr>`).join('') : '<tr><td colspan="4" class="muted">No products yet.</td></tr>'}</tbody>
          </table>
        </div>
      </div>`}
    </div>`;
}

function readScale(card) {
  const tiers = [...card.querySelectorAll('.sp-tiers tbody tr')].map((tr) => ({
    label: tr.querySelector('.sp-label').value.trim(),
    markup_percent: tr.querySelector('.sp-pct').value.trim() || '0',
    markup_amount: tr.querySelector('.sp-amt').value.trim() || '0'
  })).filter((t) => t.label || Number(t.markup_percent) || Number(t.markup_amount));
  return {
    code: card.querySelector('.sp-code').value.trim().toUpperCase(),
    name: card.querySelector('.sp-name').value.trim(),
    round_to: Number(card.querySelector('.sp-round').value || 0),
    tiers
  };
}

async function saveScale(card, btn) {
  const s = readScale(card);
  btn.disabled = true;
  const { error } = await supabaseClient.rpc('admin_save_size_scale', rpcArgs({
    p_code: s.code, p_name: s.name, p_round_to: s.round_to, p_tiers: s.tiers
  }));
  btn.disabled = false;
  if (error) return alert(error.message);
  await loadScales();
}

async function deleteScale(scale) {
  if (!confirm(`Delete the size scale "${scale.name}"? Its ${scale.items.length} product(s) go back to one price.`)) return;
  const { error } = await supabaseClient.rpc('admin_delete_size_scale', rpcArgs({ p_code: scale.code }));
  if (error) return alert(error.message);
  await loadScales();
}

async function setItemScale(itemCode, scaleCode) {
  const { error } = await supabaseClient.rpc('admin_set_item_size_scale', rpcArgs({ p_item_code: itemCode, p_scale_code: scaleCode }));
  if (error) return alert(error.message);
  await loadScales();
}

let searchTimer = null;
async function runSearch(card, input) {
  const resultsEl = card.querySelector('.sp-search-results');
  const term = input.value.trim();
  if (!term) return resultsEl.classList.add('hidden');
  const { data, error } = await supabaseClient.rpc('staff_search_items_wildcard', { p_query: term });
  if (input.value.trim() !== term) return;
  resultsEl.classList.remove('hidden');
  if (error) {
    resultsEl.innerHTML = `<div>${esc(error.message)}</div>`;
    return;
  }
  const rows = (data || []).slice(0, 30);
  resultsEl.innerHTML = rows.length
    ? rows.map((it) => `<div data-code="${esc(it.code)}"><span>${esc(it.name)} <span class="muted">${esc(it.code)}</span></span><span>${peso(it.price)}</span></div>`).join('')
    : '<div class="muted">No matching products.</div>';
}

function wire() {
  document.getElementById('refreshBtn').addEventListener('click', loadScales);
  document.getElementById('newScaleBtn').addEventListener('click', () => {
    if (scales.some((s) => s.is_new)) return;
    scales.unshift({ is_new: true, code: '', name: '', round_to: 100, tiers: [], items: [] });
    renderScales();
    document.querySelector('.sp-scale .sp-code')?.focus();
  });

  const box = document.getElementById('scalesBox');
  box.addEventListener('click', (e) => {
    const card = e.target.closest('.sp-scale');
    if (!card) return;
    const scale = scales[Number(card.dataset.index)];
    const btn = e.target.closest('[data-action]');
    const pick = e.target.closest('.sp-search-results [data-code]');
    if (pick) {
      if (confirm(`Put ${pick.textContent.trim()} on "${scale.name}"? It will move off any other size scale.`)) setItemScale(pick.dataset.code, scale.code);
      return;
    }
    if (!btn) return;
    switch (btn.dataset.action) {
      case 'save': saveScale(card, btn); break;
      case 'delete': deleteScale(scale); break;
      case 'add-tier':
        card.querySelector('.sp-tiers tbody').insertAdjacentHTML('beforeend', tierRowHtml({ label: '', markup_percent: '', markup_amount: '' }));
        break;
      case 'remove-tier': btn.closest('tr').remove(); break;
      case 'unassign': setItemScale(btn.dataset.code, null); break;
      default: break;
    }
  });
  box.addEventListener('input', (e) => {
    if (!e.target.classList.contains('sp-search')) return;
    const card = e.target.closest('.sp-scale');
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => runSearch(card, e.target), 300);
  });
  box.addEventListener('focusout', (e) => {
    if (!e.target.classList.contains('sp-search')) return;
    const resultsEl = e.target.closest('.sp-scale').querySelector('.sp-search-results');
    setTimeout(() => resultsEl.classList.add('hidden'), 200);
  });
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Size Pricing');
  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }
  document.getElementById('setupContent').classList.remove('hidden');
  wire();
  await loadScales();
})();
