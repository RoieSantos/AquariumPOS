// Price Increase page logic (super users only) - sql/supabase_price_change_batches.sql.
// The % / rounding / wholesale rule is computed here so the choices update instantly; it is the same rule as
// the read-only checks (sql/supabase_check_price_increase_2_5.sql / _wholesale_...). The server only stores
// and applies the numbers saved on the draft.
let currentSession = null;
let sourceRows = [];          // admin_price_change_source_rows
const rowState = new Map();   // key -> { include, newPrice (typed override or null), newWs (typed override or null), touched }
let editingBatchId = null;    // null = new draft
let editingStatus = null;     // 'Draft' | 'Scheduled' | null (new)
let lastComputed = [];        // rows with computed prices, for summary / save
let rateRows = [];            // admin_price_change_rate_rows - sticker / delivery rates + set Package Prices, same %
const rateState = new Map();  // key -> { include, newPrice (typed override or null) }
let lastRates = [];           // rate rows with computed new values
let activeView = '';
let shownLimit = 100;
let dirty = false;

const PAGE_SIZE = 100;
const peso = (n) => (n == null || Number.isNaN(n) ? '' : '₱' + Number(n).toLocaleString('en-PH', { minimumFractionDigits: 0, maximumFractionDigits: 2 }));
const pct = (n) => (n == null || !Number.isFinite(n) ? '' : `${n.toFixed(1)}%`);
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const rowKey = (r) => `${r.kind}|${r.item_code}|${r.variation_id || ''}`;
const lineKey = (l) => `${l.kind}|${l.item_code}|${l.variation_id || ''}`;
const num = (v) => (v == null || v === '' ? null : Number(v));
const $ = (id) => document.getElementById(id);
// weekday can't be combined with dateStyle/timeStyle (toLocaleString throws), so spell the parts out.
const fmtDate = (d) => (d ? new Date(d).toLocaleString('en-PH', { weekday: 'short', year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '');
const fmtDateShort = (d) => (d ? new Date(d).toLocaleString('en-PH', { dateStyle: 'medium', timeStyle: 'short' }) : '');
const rpcArgs = (extra) => ({ p_admin_username: currentSession.username, p_admin_password: currentSession.password, ...extra });

// Round UP to a clean price point: < 100 whole peso, < 1,000 next 5, >= 1,000 next 10. Cents are rounded
// first so floating error (100 * 1.05 = 105.00000000000001) can't push a price up a whole step.
function roundUpPrice(x) {
  if (!(x > 0)) return 0;
  const v = Math.round(x * 100) / 100;
  if (v < 100) return Math.ceil(v);
  if (v < 1000) return Math.ceil(v / 5) * 5;
  return Math.ceil(v / 10) * 10;
}

// Rates (per sq ft / per km) are small numbers, so under ₱100 they step by ₱0.50 instead of a whole peso.
function roundUpRate(x) {
  if (!(x > 0)) return 0;
  const v = Math.round(x * 100) / 100;
  return v < 100 ? Math.ceil(v * 2) / 2 : roundUpPrice(v);
}

// ---------------------------------------------------------------------------
// Dialogs / toast (in-page, instead of the browser's alert/confirm boxes)
// ---------------------------------------------------------------------------

function piConfirm(title, message, confirmLabel = 'OK', { danger = false, cancelLabel = 'Cancel' } = {}) {
  return new Promise((resolve) => {
    const modal = $('piConfirmModal');
    const yes = $('piConfirmYesBtn');
    const no = $('piConfirmNoBtn');
    $('piConfirmTitle').textContent = title;
    $('piConfirmMessage').textContent = message;
    yes.textContent = confirmLabel;
    yes.className = `btn ${danger ? 'btn-danger' : 'btn-primary'}`;
    no.textContent = cancelLabel;
    no.classList.toggle('hidden', cancelLabel === null);
    const done = (result) => {
      modal.classList.add('hidden');
      yes.onclick = null; no.onclick = null; modal.onclick = null;
      resolve(result);
    };
    yes.onclick = () => done(true);
    no.onclick = () => done(false);
    modal.onclick = (e) => { if (e.target === modal) done(false); };
    modal.classList.remove('hidden');
    yes.focus();
  });
}

const piAlert = (title, message) => piConfirm(title, message, 'OK', { cancelLabel: null });

let toastTimer = null;
function toast(message, isError = false) {
  const el = $('piToast');
  el.textContent = message;
  el.classList.toggle('pi-toast-error', isError);
  el.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.add('hidden'), isError ? 8000 : 5000);
}

function setDirty(value) {
  dirty = value;
  $('dirtyNote').classList.toggle('hidden', !dirty);
}

// ---------------------------------------------------------------------------
// Choices (step 1 / step 3)
// ---------------------------------------------------------------------------

function selectedKeep() {
  const checked = document.querySelector('input[name="wsMode"]:checked');
  return checked ? checked.value : '75';
}

function knobs() {
  const p = Number($('pctInput').value);
  const mode = selectedKeep();
  const k = mode === 'custom' || mode === 'off' ? Number($('keepInput').value) : Number(mode);
  return {
    increasePct: Number.isFinite(p) && p >= 0 ? p : 0,
    keep: Number.isFinite(k) ? Math.min(Math.max(k, 0), 100) / 100 : 1,
    wholesale: mode !== 'off',
    skipCustom: $('skipCustomToggle').checked
  };
}

function syncPctChips() {
  const v = Number($('pctInput').value);
  document.querySelectorAll('#pctChips .pi-chip').forEach((c) => c.classList.toggle('active', Number(c.dataset.pct) === v));
}

function setKeepMode(mode) {
  // A saved / typed keep % that isn't one of the presets selects the hidden "custom" radio (no card highlighted).
  document.querySelectorAll('input[name="wsMode"]').forEach((r) => { r.checked = r.value === mode; });
  document.querySelectorAll('#wsOptions .pi-option').forEach((o) => o.classList.toggle('active', o.dataset.keep === mode));
  if (mode !== 'off' && mode !== 'custom') $('keepInput').value = mode;
}

function whenMode() {
  const checked = document.querySelector('input[name="whenMode"]:checked');
  return checked ? checked.value : 'draft';
}

function setWhenMode(mode) {
  document.querySelectorAll('input[name="whenMode"]').forEach((r) => { r.checked = r.value === mode; });
  document.querySelectorAll('#whenOptions .pi-option').forEach((o) => o.classList.toggle('active', o.dataset.when === mode));
  $('scheduleRow').classList.toggle('hidden', mode !== 'schedule');
  $('scheduleHint').classList.toggle('hidden', mode !== 'schedule');
  updateBar();
}

// <input type="datetime-local"> works in the viewer's local time (Manila for the shop).
function toLocalInput(value) {
  if (!value) return '';
  const d = new Date(value);
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

// ---------------------------------------------------------------------------
// Pricing
// ---------------------------------------------------------------------------

function defaultInclude(r, k) {
  if (r.is_custom && k.skipCustom) return false;
  return (r.price ?? 0) > 0 || (r.wholesale_price ?? 0) > 0;
}

function stateFor(r, k) {
  const key = rowKey(r);
  if (!rowState.has(key)) rowState.set(key, { include: defaultInclude(r, k), newPrice: null, newWs: null, touched: false });
  return rowState.get(key);
}

function crossesRound(oldP, newP) {
  if (!(oldP > 0) || !(newP > 0)) return null;
  const step = oldP < 1000 ? 100 : 1000;
  const a = Math.floor(oldP / step), b = Math.floor(newP / step);
  return a !== b ? b * step : null;
}

// Notes: [label, badge class, explanation, level] - level 'bad' / 'warn' count as "need a look".
function compute(r, k) {
  const st = stateFor(r, k);
  const mult = 1 + k.increasePct / 100;
  const price = r.price;               // null on a multi-variant item's wholesale-only row
  const ws = r.wholesale_price;
  const calcPrice = price != null && price > 0 ? roundUpPrice(price * mult) : price;
  const newPrice = price == null ? null : (st.newPrice != null ? st.newPrice : calcPrice);

  let calcWs = null;
  if (k.wholesale && ws > 0) {
    let target = ws * mult;
    if (price > 0 && ws < price) {
      target = Math.max(target, (newPrice ?? calcPrice) * (1 - (1 - ws / price) * k.keep));
    }
    calcWs = roundUpPrice(target);
  }
  const newWs = ws > 0 ? (st.newWs != null ? st.newWs : (calcWs ?? ws)) : null;

  const retailChanges = st.include && price != null && newPrice !== price;
  const wsChanges = st.include && ws > 0 && newWs != null && newWs !== ws;
  const cost = r.cost;
  const jump = k.increasePct / 100 + 0.075;

  const notes = [];
  if (cost > 0 && newPrice > 0 && newPrice <= cost) notes.push(['Below cost', 'badge-danger', `New retail ${peso(newPrice)} is at or below the cost of ${peso(cost)}.`, 'bad']);
  else if (cost > 0 && newPrice > cost && (newPrice - cost) / newPrice < 0.15) notes.push(['Low margin', 'badge-warning', `Only ${pct((newPrice - cost) / newPrice * 100)} margin after the increase.`, 'warn']);
  if (ws > 0 && cost > 0 && newWs <= cost) notes.push(['Wholesale below cost', 'badge-danger', `New wholesale ${peso(newWs)} is at or below the cost of ${peso(cost)}.`, 'bad']);
  else if (ws > 0 && cost > 0 && newWs > cost && (newWs - cost) / newWs < 0.10) notes.push(['Low wholesale margin', 'badge-warning', `Only ${pct((newWs - cost) / newWs * 100)} margin at wholesale.`, 'warn']);
  if (ws > 0 && newPrice > 0 && newWs >= newPrice) notes.push(['Wholesale ≥ retail', 'badge-danger', 'Wholesale would be the same as or higher than retail.', 'bad']);
  if (price > 0 && newPrice > price * (1 + jump)) notes.push(['Big jump', 'badge-warning', `Retail goes up ${pct((newPrice / price - 1) * 100)}.`, 'warn']);
  if (ws > 0 && newWs > ws * (1 + jump)) notes.push(['Big wholesale jump', 'badge-warning', `Wholesale goes up ${pct((newWs / ws - 1) * 100)}.`, 'warn']);
  const crossed = crossesRound(price, newPrice);
  if (crossed) notes.push([`Passes ₱${crossed.toLocaleString('en-PH')}`, 'badge-primary', `The new price goes over ₱${crossed.toLocaleString('en-PH')}. You might prefer just under it.`, 'info']);
  if (price != null && !(cost > 0)) notes.push(['No cost entered', 'badge-neutral', 'No unit cost in Item Setup, so the margin can\'t be checked.', 'info']);
  if (r.is_custom) notes.push(['Custom item', 'badge-neutral', 'Priced by the calculators / Pricing Setup, not by this list price.', 'info']);
  if (ws > 0 && !r.wholesale_applicable) notes.push(['Wholesale not used', 'badge-neutral', 'This category isn\'t marked Wholesale Applicable, so this wholesale price is never quoted.', 'info']);
  if (!(Number(r.qty_90d) > 0)) notes.push(['Not sold lately', 'badge-neutral', 'No sales in the last 90 days.', 'info']);
  const retailOverride = r.retail_price != null && price != null && Number(r.retail_price) !== Number(price);
  if (retailOverride) notes.push([`Customers saw ${peso(r.retail_price)}`, 'badge-purple', `Order Now / Alice were still quoting an old price of ${peso(r.retail_price)}. Applying fixes that too.`, 'info']);

  const attention = st.include && notes.some((n) => n[3] === 'bad' || n[3] === 'warn');
  const extraRetail = retailChanges ? Number(r.qty_90d || 0) * (newPrice - price) : 0;
  const extraWs = wsChanges ? Number(r.ws_qty_90d || 0) * (newWs - ws) : 0;

  return {
    r, st, key: rowKey(r), price, newPrice, calcPrice, ws, newWs, calcWs, cost,
    retailChanges, wsChanges, notes, attention, retailOverride, extraRetail, extraWs
  };
}

// The toll fee is a fallback pass-through for tolls Google can't price, so it starts unticked.
const defaultIncludeRate = (r) => r.price > 0 && !(r.kind === 'delivery' && r.item_code === 'DELIVERY_TOLL_FEE');

// Set Package Prices are peso prices like items, so they round like items (not in ₱0.50 rate steps).
function computeRate(r, k) {
  const key = rowKey(r);
  if (!rateState.has(key)) rateState.set(key, { include: defaultIncludeRate(r), newPrice: null });
  const st = rateState.get(key);
  const round = r.kind === 'set' ? roundUpPrice : roundUpRate;
  const calcPrice = r.price > 0 ? round(r.price * (1 + k.increasePct / 100)) : r.price;
  const newPrice = st.newPrice != null ? st.newPrice : calcPrice;
  return { r, st, key, price: r.price, calcPrice, newPrice, changes: st.include && r.price != null && newPrice !== r.price };
}

function matchesView(c, view) {
  switch (view) {
    case 'attention': return c.attention;
    case 'changing': return c.retailChanges || c.wsChanges;
    case 'excluded': return !c.st.include;
    case 'overridden': return c.st.newPrice != null || c.st.newWs != null;
    case 'wholesale': return c.ws > 0;
    default: return true;
  }
}

function matchesSearch(c) {
  const q = $('searchInput').value.trim().toLowerCase();
  const cat = $('categoryFilter').value;
  if (q && !(`${c.r.item_code} ${c.r.name}`.toLowerCase().includes(q))) return false;
  if (cat && (c.r.category || '') !== cat) return false;
  return true;
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

function renderExample(k) {
  // Uses the best seller that has a wholesale price (or just the best seller) so the example is a real item.
  const pick = sourceRows.find((r) => r.price > 0 && r.wholesale_price > 0 && Number(r.qty_90d) > 0 && !r.is_custom)
    || sourceRows.find((r) => r.price > 0 && !r.is_custom);
  if (!pick) { $('exampleBox').textContent = ''; return; }
  const c = compute(pick, k);
  let text = `Example - <b>${esc(pick.name)}</b>: retail ${peso(c.price)} <span class="pi-arrow">→</span> <b>${peso(c.newPrice)}</b>`;
  if (c.ws > 0) {
    text += k.wholesale
      ? `, wholesale ${peso(c.ws)} <span class="pi-arrow">→</span> <b>${peso(c.newWs)}</b>`
      : `, wholesale stays ${peso(c.ws)}`;
  }
  $('exampleBox').innerHTML = text;
}

function updateBar() {
  const changing = lastComputed.filter((c) => c.retailChanges || c.wsChanges);
  const setsChanging = lastRates.filter((c) => c.changes && c.r.kind === 'set').length;
  const ratesChanging = lastRates.filter((c) => c.changes).length - setsChanging;
  const extra = changing.reduce((s, c) => s + c.extraRetail + c.extraWs, 0);
  const rateText = (ratesChanging ? ` · <b>${ratesChanging}</b> sticker/delivery rate${ratesChanging === 1 ? '' : 's'}` : '')
    + (setsChanging ? ` · <b>${setsChanging}</b> aquarium set${setsChanging === 1 ? '' : 's'}` : '');
  $('barInfo').innerHTML = changing.length
    ? `<b>${changing.length.toLocaleString('en-PH')}</b> item${changing.length === 1 ? '' : 's'} getting a new price · about <b>${peso(Math.round(extra))}</b> more every 3 months${rateText}`
    : ratesChanging || setsChanging ? `No item prices change${rateText}` : '<span class="muted">No item would change price yet.</span>';

  const mode = whenMode();
  const btn = $('primaryBtn');
  btn.className = `btn ${mode === 'now' ? 'btn-success' : 'btn-primary'}`;
  if (mode === 'now') btn.textContent = 'Apply now';
  else if (mode === 'schedule') {
    const v = $('scheduleInput').value;
    btn.textContent = v ? `Schedule for ${fmtDateShort(new Date(v))}` : 'Schedule';
  } else btn.textContent = editingBatchId ? 'Save changes' : 'Save draft';
  btn.disabled = changing.length === 0 && ratesChanging === 0 && setsChanging === 0;
}

function rateSubLabel(c) {
  if (c.r.kind === 'set') return esc(c.r.note || c.r.item_code);
  if (c.r.kind === 'sticker') return 'Sticker / accessory rate (Pricing Setup)';
  return c.price == null ? 'Not a plain number in General Setup - change it there' : 'Delivery Quote setting';
}

function renderRates(k) {
  lastRates = rateRows.map((r) => computeRate(r, k));
  renderRateTable($('rateTableBody'), lastRates.filter((c) => c.r.kind !== 'set'), 'No rates found.');
  renderRateTable($('setTableBody'), lastRates.filter((c) => c.r.kind === 'set'), 'No aquarium sets found.');
}

function renderRateTable(tbody, rows, emptyText) {
  if (!tbody.dataset.error) {
    tbody.innerHTML = rows.map((c) => {
      const upPct = c.price > 0 && c.newPrice != null ? (c.newPrice / c.price - 1) * 100 : null;
      const sub = c.st.newPrice != null
        ? `<span class="pi-sub">typed · calc. ${peso(c.calcPrice)}</span>`
        : upPct == null ? '' : upPct > 0 ? `<span class="pi-sub pi-up">+${upPct.toFixed(1)}%</span>` : '<span class="pi-sub">no change</span>';
      return `
        <tr class="${c.st.include ? '' : 'pi-row-excluded'}">
          <td><input type="checkbox" class="pi-include pi-include-box" data-key="${esc(c.key)}" ${c.st.include ? 'checked' : ''} ${c.price == null ? 'disabled' : ''} aria-label="Include ${esc(c.r.name)}" /></td>
          <td><b>${esc(c.r.name)}</b><span class="pi-sub">${rateSubLabel(c)}</span></td>
          <td class="pi-num">${peso(c.price)}</td>
          <td class="pi-num">${c.price == null ? '' : `<input type="number" class="pi-input pi-price${c.st.newPrice != null ? ' pi-overridden' : ''}" data-key="${esc(c.key)}" min="0" step="any" value="${c.newPrice ?? ''}" aria-label="New ${esc(c.r.name)}" /> ${sub}`}</td>
        </tr>`;
    }).join('') || `<tr><td colspan="4" class="muted">${emptyText}</td></tr>`;
  }
}

function render() {
  const k = knobs();
  syncPctChips();
  renderExample(k);
  renderRates(k);
  lastComputed = sourceRows.map((r) => compute(r, k));

  // Tiles + tab counts (over everything, not just the search).
  const changing = lastComputed.filter((c) => c.retailChanges || c.wsChanges);
  const retailN = changing.filter((c) => c.retailChanges).length;
  const wsN = changing.filter((c) => c.wsChanges).length;
  const extraRetail = changing.reduce((s, c) => s + c.extraRetail, 0);
  const extraWs = changing.reduce((s, c) => s + c.extraWs, 0);
  $('sumItems').textContent = changing.length.toLocaleString('en-PH');
  $('sumItemsSub').textContent = `${retailN} retail · ${wsN} wholesale`;
  $('sumExtra').textContent = peso(Math.round(extraRetail + extraWs));
  $('sumExtraSub').textContent = `${peso(Math.round(extraRetail))} retail + ${peso(Math.round(extraWs))} wholesale, if the same amounts sell`;
  $('sumFlags').textContent = lastComputed.filter((c) => c.attention).length.toLocaleString('en-PH');
  const counts = { cntAll: '', cntAttention: 'attention', cntChanging: 'changing', cntExcluded: 'excluded', cntOverridden: 'overridden', cntWholesale: 'wholesale' };
  Object.entries(counts).forEach(([id, view]) => { $(id).textContent = lastComputed.filter((c) => matchesView(c, view)).length; });
  document.querySelectorAll('#viewTabs .pi-chip').forEach((b) => b.classList.toggle('active', b.dataset.view === activeView));

  updateBar();

  const shown = lastComputed.filter((c) => matchesView(c, activeView) && matchesSearch(c));
  $('shownCount').textContent = `${shown.length.toLocaleString('en-PH')} item${shown.length === 1 ? '' : 's'} shown`;
  $('rowsTableWrap').classList.toggle('pi-show-details', $('detailsToggle').checked);

  const tbody = $('rowsTableBody');
  if (shown.length === 0) {
    tbody.innerHTML = `<tr><td colspan="11" class="muted" style="text-align:center; padding:20px;">${activeView === 'attention' ? 'Nothing needs a look - all good.' : 'No items match.'}</td></tr>`;
    $('moreRowsBox').classList.add('hidden');
    return;
  }

  const page = shown.slice(0, shownLimit);
  tbody.innerHTML = page.map(rowHtml).join('');
  $('moreRowsBox').classList.toggle('hidden', shown.length <= shownLimit);
  $('moreRowsBtn').textContent = `Show more (${(shown.length - shownLimit).toLocaleString('en-PH')} left)`;
}

function rowHtml(c) {
  const r = c.r;
  const marginNow = c.cost > 0 && c.price > 0 ? (c.price - c.cost) / c.price * 100 : null;
  const marginNew = c.cost > 0 && c.newPrice > 0 ? (c.newPrice - c.cost) / c.newPrice * 100 : null;
  const offNow = c.ws > 0 && c.price > 0 ? (1 - c.ws / c.price) * 100 : null;
  const offNew = c.ws > 0 && c.newPrice > 0 ? (1 - c.newWs / c.newPrice) * 100 : null;
  const upPct = c.price > 0 && c.newPrice != null ? (c.newPrice / c.price - 1) * 100 : null;
  const wsUpPct = c.ws > 0 && c.newWs != null ? (c.newWs / c.ws - 1) * 100 : null;
  const upLabel = (v) => (v == null ? '' : v > 0 ? `<span class="pi-sub pi-up">+${v.toFixed(1)}%</span>` : '<span class="pi-sub">no change</span>');
  const typedNote = (typed, calc) => (typed ? `<span class="pi-sub">typed · calc. ${peso(calc)}</span>` : '');

  const retailCell = c.price == null
    ? '<span class="pi-sub">each variant has its own price</span>'
    : `<input type="number" class="pi-input pi-price${c.st.newPrice != null ? ' pi-overridden' : ''}" data-key="${esc(c.key)}" min="0" step="any" value="${c.newPrice ?? ''}" aria-label="New retail for ${esc(r.item_code)}" />
       ${c.st.newPrice != null ? typedNote(true, c.calcPrice) : upLabel(upPct)}`;
  const wsCell = c.ws > 0
    ? `<input type="number" class="pi-input pi-ws${c.st.newWs != null ? ' pi-overridden' : ''}" data-key="${esc(c.key)}" min="0" step="any" value="${c.newWs ?? ''}" aria-label="New wholesale for ${esc(r.item_code)}" />
       ${c.st.newWs != null ? typedNote(true, c.calcWs ?? c.ws) : upLabel(wsUpPct)}`
    : '<span class="pi-sub">-</span>';
  const sold = Number(r.qty_90d || 0);
  const soldWs = Number(r.ws_qty_90d || 0);

  return `
    <tr class="${c.st.include ? '' : 'pi-row-excluded'}">
      <td><input type="checkbox" class="pi-include pi-include-box" data-key="${esc(c.key)}" ${c.st.include ? 'checked' : ''} aria-label="Include ${esc(r.item_code)}" /></td>
      <td><b>${esc(r.name)}</b><span class="pi-sub">${esc(r.item_code)}${r.category ? ` · ${esc(r.category)}` : ''}${r.is_active ? '' : ' · inactive'}</span></td>
      <td class="pi-num">${c.price == null ? '' : peso(c.price)}</td>
      <td class="pi-num">${retailCell}</td>
      <td class="pi-num">${c.ws > 0 ? peso(c.ws) : ''}</td>
      <td class="pi-num">${wsCell}</td>
      <td class="pi-num pi-details-col">${c.cost > 0 ? peso(c.cost) : '<span class="pi-sub">not set</span>'}</td>
      <td class="pi-num pi-details-col">${marginNow != null ? `${pct(marginNow)}<span class="pi-arrow">→</span>${pct(marginNew)}` : ''}</td>
      <td class="pi-num pi-details-col">${offNow != null ? `${pct(offNow)}<span class="pi-arrow">→</span>${pct(offNew)}` : ''}</td>
      <td class="pi-num pi-hide-sm">${sold.toLocaleString('en-PH')}${soldWs > 0 ? `<span class="pi-sub">${soldWs.toLocaleString('en-PH')} at wholesale</span>` : ''}</td>
      <td class="pi-notes">${c.notes.map(([label, cls, why]) => `<span class="badge ${cls}" title="${esc(why)}">${esc(label)}</span>`).join('')}</td>
    </tr>`;
}

// ---------------------------------------------------------------------------
// Table events
// ---------------------------------------------------------------------------

function bindTable() {
  // Delegated so a re-render doesn't need re-binding. Typed prices re-render on change (not every keystroke).
  $('rowsTableBody').addEventListener('change', (e) => {
    const el = e.target;
    const st = rowState.get(el.dataset.key);
    if (!st) return;
    if (el.classList.contains('pi-include')) {
      st.include = el.checked;
    } else if (el.classList.contains('pi-price') || el.classList.contains('pi-ws')) {
      const field = el.classList.contains('pi-price') ? 'newPrice' : 'newWs';
      const c = lastComputed.find((x) => x.key === el.dataset.key);
      const v = num(el.value);
      const calc = field === 'newPrice' ? c?.calcPrice : (c?.calcWs ?? c?.ws);
      st[field] = v == null || v < 0 || v === calc ? null : Math.round(v * 100) / 100;
      if (st[field] != null) st.include = true;
    }
    st.touched = true;
    setDirty(true);
    render();
  });
  // Enter in a price box moves to the next one (fast keyboard entry down the list).
  $('rowsTableBody').addEventListener('keydown', (e) => {
    if (e.key !== 'Enter' || !e.target.classList.contains('pi-input')) return;
    e.preventDefault();
    const inputs = [...document.querySelectorAll(`#rowsTableBody .${e.target.classList.contains('pi-price') ? 'pi-price' : 'pi-ws'}`)];
    const i = inputs.indexOf(e.target);
    const key = inputs[i + 1]?.dataset.key;
    e.target.dispatchEvent(new Event('change', { bubbles: true }));
    if (key) document.querySelector(`#rowsTableBody .${e.target.classList.contains('pi-price') ? 'pi-price' : 'pi-ws'}[data-key="${CSS.escape(key)}"]`)?.select();
  });
}

function bindRateTable(tbody) {
  tbody.addEventListener('change', (e) => {
    const el = e.target;
    const st = rateState.get(el.dataset.key);
    if (!st) return;
    if (el.classList.contains('pi-include')) {
      st.include = el.checked;
    } else if (el.classList.contains('pi-price')) {
      const c = lastRates.find((x) => x.key === el.dataset.key);
      const v = num(el.value);
      st.newPrice = v == null || v < 0 || v === c?.calcPrice ? null : Math.round(v * 100) / 100;
      if (st.newPrice != null) st.include = true;
    }
    setDirty(true);
    render();
  });
}

function setShown(fn) {
  lastComputed.filter((c) => matchesView(c, activeView) && matchesSearch(c)).forEach((c) => { fn(c.st); c.st.touched = true; });
  setDirty(true);
  render();
}

function fillCategoryFilter() {
  const sel = $('categoryFilter');
  const cats = [...new Set(sourceRows.map((r) => r.category || ''))].filter(Boolean).sort();
  const current = sel.value;
  sel.innerHTML = '<option value="">All categories</option>' + cats.map((c) => `<option value="${esc(c)}">${esc(c)}</option>`).join('');
  sel.value = cats.includes(current) ? current : '';
}

function showNotice(text) {
  $('editorNotice').textContent = text || '';
  $('editorNotice').classList.toggle('hidden', !text);
}

// ---------------------------------------------------------------------------
// Editor open / close
// ---------------------------------------------------------------------------

async function loadSourceRows() {
  $('rowsTableBody').innerHTML = '<tr><td colspan="11" class="muted" style="text-align:center; padding:20px;">Loading items and sales...</td></tr>';
  const { data, error } = await supabaseClient.rpc('admin_price_change_source_rows', rpcArgs());
  if (error) throw error;
  sourceRows = (data || []).map((r) => ({
    ...r,
    price: num(r.price), retail_price: num(r.retail_price), cost: num(r.cost), wholesale_price: num(r.wholesale_price)
  }));
  sourceRows.sort((a, b) => Number(b.revenue_90d || 0) - Number(a.revenue_90d || 0)
    || Number(b.revenue_365d || 0) - Number(a.revenue_365d || 0) || a.item_code.localeCompare(b.item_code));
  fillCategoryFilter();
}

// Never blocks the items: if the rates can't load (e.g. the SQL wasn't re-run yet), the table says so.
async function loadRateRows() {
  const tbodies = [$('rateTableBody'), $('setTableBody')];
  tbodies.forEach((t) => delete t.dataset.error);
  rateRows = [];
  const { data, error } = await supabaseClient.rpc('admin_price_change_rate_rows', rpcArgs());
  if (error) {
    tbodies.forEach((t) => {
      t.dataset.error = '1';
      t.innerHTML = `<tr><td colspan="4" class="error-text">Couldn't load rates &amp; sets: ${esc(error.message)}</td></tr>`;
    });
    return;
  }
  const order = { DELIVERY_BASE_FEE: 1, DELIVERY_RATE_PER_KM: 2, DELIVERY_TOLL_FEE: 3 };
  const kindOrder = { sticker: 1, delivery: 2, set: 3 };
  rateRows = (data || []).map((r) => ({ ...r, variation_id: null, price: num(r.price) }))
    .sort((a, b) => (kindOrder[a.kind] || 9) - (kindOrder[b.kind] || 9)
      || (order[a.item_code] || 0) - (order[b.item_code] || 0) || a.name.localeCompare(b.name, undefined, { numeric: true }));
}

function showEditor(show) {
  $('editorBox').classList.toggle('hidden', !show);
  $('historyBox').classList.toggle('hidden', show);
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

async function openEditor(batchId) {
  editingBatchId = batchId || null;
  editingStatus = null;
  rowState.clear();
  rateState.clear();
  activeView = '';
  shownLimit = PAGE_SIZE;
  $('searchInput').value = '';
  $('categoryFilter').value = '';
  showNotice('');
  setDirty(false);
  showEditor(true);
  $('editorTitle').textContent = batchId ? `Price change #${batchId}` : 'New price increase';

  try {
    await Promise.all([loadSourceRows(), loadRateRows()]);
  } catch (err) {
    $('rowsTableBody').innerHTML = `<tr><td colspan="11" class="error-text">${esc(err.message)}</td></tr>`;
    return;
  }

  if (!batchId) {
    $('descInput').value = '';
    $('pctInput').value = 5;
    $('scheduleInput').value = '';
    setKeepMode('75');
    setWhenMode('draft');
    render();
    return;
  }

  // Re-open a draft against TODAY's prices: lines whose old price still matches keep the saved new price
  // (as a typed price if it differs from the calculation); items not on the draft are left out; items whose
  // price changed since are recalculated from the current price and called out.
  const { data, error } = await supabaseClient.rpc('admin_price_change_get', rpcArgs({ p_batch_id: batchId }));
  if (error) { showNotice(error.message); return; }

  editingStatus = data.status;
  $('descInput').value = data.description || '';
  $('scheduleInput').value = toLocalInput(data.scheduled_for_utc);
  if (data.description) $('editorTitle').textContent = `#${batchId} ${data.description}`;
  if (data.increase_pct != null) $('pctInput').value = Number(data.increase_pct);
  const keepPct = data.keep_discount != null ? Math.round(Number(data.keep_discount) * 100) : 75;
  const hasWs = (data.lines || []).some((l) => l.new_wholesale_price != null);
  $('keepInput').value = keepPct;
  setKeepMode(!hasWs ? 'off' : ['100', '75', '50'].includes(String(keepPct)) ? String(keepPct) : 'custom');
  setWhenMode(data.status === 'Scheduled' ? 'schedule' : 'draft');

  const k = knobs();
  const saved = new Map((data.lines || []).map((l) => [lineKey(l), l]));
  const changedSince = [];
  sourceRows.forEach((r) => {
    const key = rowKey(r);
    const l = saved.get(key);
    const st = { include: false, newPrice: null, newWs: null, touched: true };
    rowState.set(key, st);
    if (!l) return;
    st.include = true;
    const priceMoved = l.new_price != null && num(l.old_price) !== r.price;
    const wsMoved = l.new_wholesale_price != null && num(l.old_wholesale_price) !== r.wholesale_price;
    if (priceMoved || wsMoved) { changedSince.push(r.name || r.item_code); return; }
    const c = compute(r, k);
    if (l.new_price != null && num(l.new_price) !== c.calcPrice) st.newPrice = num(l.new_price);
    if (l.new_price == null && r.price != null) st.newPrice = r.price; // retail was deliberately left as is
    const c2 = compute(r, k);
    if (l.new_wholesale_price != null && num(l.new_wholesale_price) !== (c2.calcWs ?? c2.ws)) st.newWs = num(l.new_wholesale_price);
    if (l.new_wholesale_price == null && r.wholesale_price > 0) st.newWs = r.wholesale_price;
  });
  // Rates: same rule - a saved rate whose old value still matches keeps its saved new value.
  const ratesChangedSince = [];
  rateRows.forEach((r) => {
    const key = rowKey(r);
    const l = saved.get(key);
    const st = { include: false, newPrice: null };
    rateState.set(key, st);
    if (!l) return;
    st.include = r.price != null;
    if (num(l.old_price) !== r.price) { ratesChangedSince.push(r.name); return; }
    if (num(l.new_price) !== computeRate(r, k).calcPrice) st.newPrice = num(l.new_price);
  });

  const listed = new Set([...sourceRows, ...rateRows].map(rowKey));
  const missing = (data.lines || []).filter((l) => !listed.has(lineKey(l)));
  const notes = [];
  if (data.apply_error) notes.push(`The scheduled run didn't go through: ${data.apply_error}`);
  if (changedSince.length) notes.push(`${changedSince.length} item price(s) were changed since this was saved, so they were recalculated from today's price: ${changedSince.slice(0, 8).join(', ')}${changedSince.length > 8 ? ` and ${changedSince.length - 8} more` : ''}.`);
  if (ratesChangedSince.length) notes.push(`These rates were changed since this was saved, so they were recalculated from today's rate: ${ratesChangedSince.join(', ')}.`);
  if (missing.length) {
    // Older drafts could hold a set as an ITEM line - sets now have their own lines from the Aquarium sets table.
    const sets = missing.filter((l) => l.kind !== 'set' && /^(AS|SET)-/i.test(l.item_code)).length;
    notes.push(`${missing.length} item(s) on it are no longer listed and will be dropped when you save${sets ? ` - ${sets} of them are aquarium sets saved as items; raise them in the Aquarium sets table instead` : ' (deleted, or inactive and unsold)'}.`);
  }
  showNotice(notes.join(' '));
  if (changedSince.length || ratesChangedSince.length || missing.length) setDirty(true);
  render();
}

async function closeEditor({ force = false } = {}) {
  if (!force && dirty) {
    const ok = await piConfirm('Leave without saving?', 'Your changes to this price increase haven\'t been saved.', 'Leave', { danger: true, cancelLabel: 'Keep editing' });
    if (!ok) return;
  }
  editingBatchId = null;
  setDirty(false);
  showEditor(false);
  await loadBatches();
}

// ---------------------------------------------------------------------------
// Save / apply / schedule
// ---------------------------------------------------------------------------

function buildLines() {
  return lastComputed
    .filter((c) => c.retailChanges || c.wsChanges)
    .map((c) => ({
      kind: c.r.kind,
      item_code: c.r.item_code,
      variation_id: c.r.variation_id || null,
      name: c.r.name,
      old_price: c.price,
      new_price: c.retailChanges ? c.newPrice : null,
      old_wholesale_price: c.ws,
      new_wholesale_price: c.wsChanges ? c.newWs : null
    }))
    .concat(lastRates.filter((c) => c.changes).map((c) => ({
      kind: c.r.kind,
      item_code: c.r.item_code,
      variation_id: null,
      name: c.r.name,
      old_price: c.price,
      new_price: c.newPrice,
      old_wholesale_price: null,
      new_wholesale_price: null
    })));
}

async function saveDraft() {
  const lines = buildLines();
  if (lines.length === 0) { await piAlert('Nothing to save', 'No item or rate would get a new price.'); return null; }
  const k = knobs();
  const { data, error } = await supabaseClient.rpc('admin_price_change_save', rpcArgs({
    p_batch_id: editingBatchId,
    p_description: $('descInput').value.trim() || null,
    p_increase_pct: k.increasePct,
    p_keep_discount: k.keep,
    p_lines: lines
  }));
  if (error) { await piAlert('Couldn\'t save', error.message); return null; }
  editingBatchId = data;
  $('editorTitle').textContent = `Price change #${data}`;
  setDirty(false);
  return data;
}

async function confirmApply(lineCount) {
  return piConfirm(
    'Apply the new prices now?',
    `${lineCount.toLocaleString('en-PH')} price(s) / rate(s) change right away. Order Now, Alice, the price list and delivery quotes use them immediately, and the store POS on its next sync.\n\nYou can undo it later from the list.`,
    'Apply now'
  );
}

async function runApply(batchId) {
  const { data, error } = await supabaseClient.rpc('admin_price_change_apply', rpcArgs({ p_batch_id: batchId }));
  if (error) { await piAlert('Not applied', error.message); return false; }
  toast(`Done - ${data.retail_updated} retail and ${data.wholesale_updated} wholesale price(s)${data.rates_updated ? `, ${data.rates_updated} sticker/delivery rate(s)` : ''}${data.sets_updated ? `, ${data.sets_updated} aquarium set(s)` : ''} updated.`);
  return true;
}

async function schedule(batchId, when) {
  const { error } = await supabaseClient.rpc('admin_price_change_schedule', rpcArgs({ p_batch_id: batchId, p_scheduled_for: when ? when.toISOString() : null }));
  if (error) { await piAlert('Not scheduled', error.message); return false; }
  return true;
}

async function onPrimary() {
  const mode = whenMode();
  const btn = $('primaryBtn');
  const lines = buildLines();
  if (lines.length === 0) return;

  let when = null;
  if (mode === 'schedule') {
    const v = $('scheduleInput').value;
    if (!v) { await piAlert('Pick a date', 'Choose the date and time it should apply.'); return; }
    when = new Date(v);
    if (!(when > new Date(Date.now() + 60000))) { await piAlert('That time has passed', 'Pick a time in the future, or choose Apply now.'); return; }
  }
  if (mode === 'now' && !(await confirmApply(lines.length))) return;

  btn.disabled = true;
  const label = btn.textContent;
  btn.textContent = 'Saving...';
  try {
    const id = await saveDraft();
    if (!id) return;
    if (mode === 'now') {
      if (!(await runApply(id))) return;
    } else if (mode === 'schedule') {
      if (!(await schedule(id, when))) return;
      toast(`Scheduled - ${lines.length.toLocaleString('en-PH')} price(s) / rate(s) change on ${fmtDate(when)}.`);
    } else {
      // Saving a scheduled one as "Save for later" takes it off the schedule.
      if (editingStatus === 'Scheduled' && !(await schedule(id, null))) return;
      toast(`Saved as a draft - nothing has changed yet.`);
    }
    await closeEditor({ force: true });
  } finally {
    btn.disabled = false;
    btn.textContent = label;
    updateBar();
  }
}

function nextMidnight(monthStart) {
  const d = new Date();
  if (monthStart) return new Date(d.getFullYear(), d.getMonth() + 1, 1, 0, 0);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1, 0, 0);
}

// ---------------------------------------------------------------------------
// History list
// ---------------------------------------------------------------------------

const STATUS_BADGE = { Draft: 'badge-warning', Scheduled: 'badge-primary', Applied: 'badge-success', Undone: 'badge-neutral' };

async function loadBatches() {
  const box = $('batchList');
  const { data, error } = await supabaseClient.rpc('admin_price_change_list', rpcArgs());
  if (error) { box.innerHTML = `<p class="error-text">${esc(error.message)}</p>`; return; }
  if (!data || data.length === 0) {
    box.innerHTML = `<div class="pi-empty"><b>No price changes yet</b>Start one to see every item's new price before anything changes.<div style="margin-top:12px;"><button class="btn btn-primary" data-act="new" type="button">+ New price increase</button></div></div>`;
    return;
  }
  try {
    box.innerHTML = data.map(batchCardHtml).join('');
  } catch (err) {
    // Never leave the list stuck on "Loading..." - show what went wrong.
    box.innerHTML = `<p class="error-text">Couldn't show the price changes: ${esc(err.message)}</p>`;
  }
}

function batchCardHtml(b) {
  const title = `#${b.batch_id} ${esc(b.description || `+${Number(b.increase_pct ?? 0)}% price increase`)}`;
  const parts = [];
  if (b.increase_pct != null) parts.push(`+${Number(b.increase_pct)}%`);
  parts.push(`${b.retail_lines} retail`);
  if (b.wholesale_lines) parts.push(`${b.wholesale_lines} wholesale`);
  if (b.rate_lines) parts.push(`${b.rate_lines} sticker/delivery rate${b.rate_lines === 1 ? '' : 's'}`);
  if (b.set_lines) parts.push(`${b.set_lines} aquarium set${b.set_lines === 1 ? '' : 's'}`);
  let when = '';
  if (b.status === 'Scheduled') when = `🗓️ Applies <b>${fmtDate(b.scheduled_for_utc)}</b> · scheduled by ${esc(b.scheduled_by || '')}`;
  else if (b.status === 'Applied') when = `✅ Applied ${fmtDate(b.applied_at_utc)} by ${esc(b.applied_by || '')}${b.skipped_lines ? ` · <span style="color:#b45309;">${b.skipped_lines} skipped (price was changed before it ran)</span>` : ''}`;
  else if (b.status === 'Undone') when = `↩️ Undone ${fmtDate(b.undone_at_utc)} by ${esc(b.undone_by || '')}${b.undo_skipped ? ` · ${b.undo_skipped} left as they were (edited after the increase)` : ''}`;
  else when = `Saved ${fmtDate(b.updated_at_utc || b.created_at_utc)} by ${esc(b.updated_by || b.created_by || '')} · nothing has changed yet`;
  const failed = b.apply_error ? `<div class="pi-batch-when error-text">The scheduled run didn't go through (${fmtDateShort(b.apply_error_at_utc)}): ${esc(b.apply_error)}</div>` : '';

  let actions;
  if (b.status === 'Draft' || b.status === 'Scheduled') {
    actions = `<button class="btn btn-primary btn-sm" data-act="open" data-id="${b.batch_id}" type="button">${b.status === 'Draft' ? 'Continue' : 'Edit'}</button>
      <button class="btn btn-success btn-sm" data-act="apply" data-id="${b.batch_id}" data-lines="${b.line_count}" type="button">Apply now</button>
      ${b.status === 'Scheduled' ? `<button class="btn btn-secondary btn-sm" data-act="unschedule" data-id="${b.batch_id}" type="button">Unschedule</button>` : ''}
      <button class="btn btn-secondary btn-sm" data-act="delete" data-id="${b.batch_id}" type="button">Delete</button>`;
  } else {
    actions = `<button class="btn btn-secondary btn-sm" data-act="view" data-id="${b.batch_id}" type="button">See prices</button>
      ${b.status === 'Applied' ? `<button class="btn btn-danger btn-sm" data-act="undo" data-id="${b.batch_id}" type="button">Undo</button>` : ''}`;
  }
  return `
    <div class="pi-batch">
      <div class="pi-batch-main">
        <div class="pi-batch-title">${title} <span class="badge ${STATUS_BADGE[b.status] || 'badge-neutral'}">${esc(b.status)}</span></div>
        <div class="pi-batch-meta">${parts.join(' · ')}</div>
        <div class="pi-batch-when">${when}</div>
        ${failed}
      </div>
      <div class="pi-batch-actions">${actions}</div>
    </div>`;
}

async function viewBatch(batchId) {
  const { data, error } = await supabaseClient.rpc('admin_price_change_get', rpcArgs({ p_batch_id: batchId }));
  if (error) { toast(error.message, true); return; }
  const lines = data.lines || [];
  const skipped = lines.filter((l) => l.skipped).length;
  $('viewTitle').textContent = `#${data.batch_id} ${data.description || 'Price change'}`;
  $('viewSub').textContent = `${data.status}${data.applied_at_utc ? ` ${fmtDate(data.applied_at_utc)} by ${data.applied_by || ''}` : ''} · ${lines.length} item(s)${skipped ? ` · ${skipped} skipped` : ''}`;
  const change = (o, n) => (n == null ? '<span class="pi-sub">-</span>' : `${peso(num(o))}<span class="pi-arrow">→</span><b>${peso(num(n))}</b>`);
  $('viewTableBody').innerHTML = lines.map((l) => `
    <tr>
      <td><b>${esc(l.name || l.item_code)}</b><span class="pi-sub">${l.kind === 'sticker' ? 'Sticker / accessory rate' : l.kind === 'delivery' ? 'Delivery Quote setting' : l.kind === 'set' ? `Aquarium set · ${esc(l.item_code)}` : esc(l.item_code)}</span></td>
      <td class="pi-num">${change(l.old_price, l.new_price)}</td>
      <td class="pi-num">${change(l.old_wholesale_price, l.new_wholesale_price)}</td>
      <td>${l.skipped ? `<span class="badge badge-warning">Skipped</span> <span class="pi-sub">${esc(l.skip_reason || '')}</span>` : ''}${l.retail_price_cleared ? `<span class="pi-sub">customers were seeing ${peso(num(l.old_retail_price))}</span>` : ''}</td>
    </tr>`).join('') || '<tr><td colspan="4" class="muted">No items.</td></tr>';
  $('piViewModal').classList.remove('hidden');
}

function bindBatchList() {
  $('batchList').addEventListener('click', async (e) => {
    const btn = e.target.closest('button[data-act]');
    if (!btn) return;
    const id = Number(btn.dataset.id);
    const act = btn.dataset.act;
    btn.disabled = true;
    try {
      if (act === 'new') await openEditor(null);
      else if (act === 'open') await openEditor(id);
      else if (act === 'view') await viewBatch(id);
      else if (act === 'apply') {
        if (await confirmApply(Number(btn.dataset.lines)) && await runApply(id)) await loadBatches();
      } else if (act === 'unschedule') {
        if (await piConfirm('Unschedule it?', `#${id} goes back to a draft. No prices change.`, 'Unschedule') && await schedule(id, null)) {
          toast('Unscheduled - it\'s a draft again.');
          await loadBatches();
        }
      } else if (act === 'delete') {
        if (await piConfirm('Delete this price change?', `#${id} hasn't been applied, so no prices change. This can't be undone.`, 'Delete', { danger: true })) {
          const { error } = await supabaseClient.rpc('admin_price_change_delete', rpcArgs({ p_batch_id: id }));
          if (error) toast(error.message, true); else { toast('Deleted.'); await loadBatches(); }
        }
      } else if (act === 'undo') {
        if (await piConfirm('Undo this price change?', `Every price #${id} changed goes back to what it was before.\n\nAny price someone has edited since is left alone.`, 'Undo prices', { danger: true })) {
          const { data, error } = await supabaseClient.rpc('admin_price_change_undo', rpcArgs({ p_batch_id: id }));
          if (error) toast(error.message, true);
          else {
            toast(`Undone - ${data.retail_restored} retail and ${data.wholesale_restored} wholesale price(s)${data.rates_restored ? `, ${data.rates_restored} sticker/delivery rate(s)` : ''}${data.sets_restored ? `, ${data.sets_restored} aquarium set(s)` : ''} restored${data.skipped ? `, ${data.skipped} left alone` : ''}.`);
            await loadBatches();
          }
        }
      }
    } finally {
      btn.disabled = false;
    }
  });
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Price Increase');

  if (!session.isSuperUser) {
    $('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    $('unlockBox').classList.remove('hidden');
    $('unlockError').textContent = 'Please log out and log back in to use Price Increase.';
    $('unlockBtn').addEventListener('click', logout);
    return;
  }

  $('setupContent').classList.remove('hidden');
  bindTable();
  bindRateTable($('rateTableBody'));
  bindRateTable($('setTableBody'));
  bindBatchList();

  const changed = () => { setDirty(true); render(); };
  const refilter = () => { shownLimit = PAGE_SIZE; render(); };

  $('newBatchBtn').addEventListener('click', () => openEditor(null));
  $('refreshBatchesBtn').addEventListener('click', loadBatches);
  $('backBtn').addEventListener('click', () => closeEditor());
  $('closeViewBtn').addEventListener('click', () => $('piViewModal').classList.add('hidden'));
  $('piViewModal').addEventListener('click', (e) => { if (e.target.id === 'piViewModal') $('piViewModal').classList.add('hidden'); });

  // Step 1
  $('pctChips').addEventListener('click', (e) => {
    const chip = e.target.closest('.pi-chip');
    if (!chip) return;
    $('pctInput').value = chip.dataset.pct;
    changed();
  });
  $('pctInput').addEventListener('input', changed);
  $('wsOptions').addEventListener('change', (e) => { if (e.target.name === 'wsMode') { setKeepMode(e.target.value); changed(); } });
  $('keepInput').addEventListener('input', () => {
    const v = String(Number($('keepInput').value));
    setKeepMode(['100', '75', '50'].includes(v) ? v : 'custom');
    changed();
  });
  $('descInput').addEventListener('input', () => setDirty(true));
  $('skipCustomToggle').addEventListener('change', () => {
    // Only re-default rows nobody has ticked / unticked by hand.
    const k = knobs();
    sourceRows.forEach((r) => { const st = rowState.get(rowKey(r)); if (st && !st.touched) st.include = defaultInclude(r, k); });
    changed();
  });

  // Step 2
  $('viewTabs').addEventListener('click', (e) => {
    const chip = e.target.closest('.pi-chip');
    if (!chip) return;
    activeView = chip.dataset.view;
    refilter();
  });
  $('attentionTile').addEventListener('click', () => { activeView = 'attention'; refilter(); $('viewTabs').scrollIntoView({ behavior: 'smooth', block: 'start' }); });
  $('searchInput').addEventListener('input', refilter);
  $('categoryFilter').addEventListener('change', refilter);
  $('detailsToggle').addEventListener('change', render);
  $('moreRowsBtn').addEventListener('click', () => { shownLimit += PAGE_SIZE; render(); });
  $('includeShownBtn').addEventListener('click', () => setShown((st) => { st.include = true; }));
  $('excludeShownBtn').addEventListener('click', () => setShown((st) => { st.include = false; }));
  $('clearOverridesBtn').addEventListener('click', () => setShown((st) => { st.newPrice = null; st.newWs = null; }));

  // Step 3
  $('whenOptions').addEventListener('change', (e) => { if (e.target.name === 'whenMode') setWhenMode(e.target.value); });
  $('scheduleInput').addEventListener('input', () => { setDirty(true); updateBar(); });
  $('pickTomorrowBtn').addEventListener('click', () => { $('scheduleInput').value = toLocalInput(nextMidnight(false)); setDirty(true); updateBar(); });
  $('pickMonthBtn').addEventListener('click', () => { $('scheduleInput').value = toLocalInput(nextMidnight(true)); setDirty(true); updateBar(); });
  $('primaryBtn').addEventListener('click', onPrimary);

  window.addEventListener('beforeunload', (e) => {
    if (!dirty || $('editorBox').classList.contains('hidden')) return;
    e.preventDefault();
    e.returnValue = '';
  });
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    if (!$('piViewModal').classList.contains('hidden')) $('piViewModal').classList.add('hidden');
  });

  await loadBatches();
})();
