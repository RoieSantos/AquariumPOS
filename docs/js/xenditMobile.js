// Xendit phone app (super users only) - per "create a mobile app for this Xendit Ledger Entries only for super
// user so I can monitor the ins and out". Same data as Xendit Ledger Entries (Edge Function xendit-ledger:
// balance + transactions, matched to our orders), laid out for a phone and installable as its own home-screen
// app (xendit-manifest.json). Read-only.
let session = null;
let allRows = [];
let viewRows = [];
let view = 'all';           // all / in / out / fees
let period = 'today';
let mode = 'live';
let shown = 60;             // list rows drawn; "Show more" adds another page
let loadToken = 0;
let lastLoaded = 0;
let searchTimer = null;

const MODE_KEY = 'xendit-mobile-mode';
const PERIOD_KEY = 'xendit-mobile-period';
const PAGE = 60;

const TYPE_LABELS = {
  PAYMENT: 'Payment', DISBURSEMENT: 'Disbursement', BATCH_DISBURSEMENT: 'Disbursement', WITHDRAWAL: 'Withdrawal',
  REFUND: 'Refund', TRANSFER: 'Transfer', TOPUP: 'Top Up', REMITTANCE_PAYOUT: 'Payout', REMITTANCE: 'Remittance'
};
const SOURCE_LABELS = { Online: 'Pay link', POS: 'POS', Delivery: 'Delivery QR' };

const $ = (id) => document.getElementById(id);

function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function amount(v) {
  return Number(v || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}
function peso(v) {
  return v == null ? '-' : '₱' + amount(v);
}
function typeLabel(t) {
  return TYPE_LABELS[t] || String(t || '').replace(/_/g, ' ').toLowerCase().replace(/\b\w/g, (c) => c.toUpperCase());
}
function statusLabel(s) {
  return String(s || '').charAt(0) + String(s || '').slice(1).toLowerCase();
}
function isOut(r) {
  return r.cashflow === 'MONEY_OUT';
}
function isOk(r) {
  return r.status === 'SUCCESS';
}
function feeOf(r) {
  return (Number(r.xendit_fee) || 0) + (Number(r.vat) || 0);
}
function netOf(r) {
  return r.net_amount != null ? Number(r.net_amount) : (Number(r.amount) || 0) - feeOf(r);
}
function settlementLabel(r) {
  if (isOut(r) || !r.settlement_status || !isOk(r)) return '';
  if (r.settlement_status === 'SETTLED' || r.settlement_status === 'EARLY_SETTLED') return 'Settled';
  return r.estimated_settlement ? `Due ${new Date(r.estimated_settlement).toLocaleDateString()}` : 'Pending';
}
function store(key, value) {
  try { localStorage.setItem(key, value); } catch {}
}
function recall(key) {
  try { return localStorage.getItem(key); } catch { return null; }
}

function periodRange() {
  const now = new Date();
  let from = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  let to = new Date(from);
  if (period === 'yesterday') { from.setDate(from.getDate() - 1); to = new Date(from); }
  if (period === '7d') from.setDate(from.getDate() - 6);
  if (period === 'month') from = new Date(now.getFullYear(), now.getMonth(), 1);
  if (period === 'lastmonth') {
    from = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    to = new Date(now.getFullYear(), now.getMonth(), 0);
  }
  to.setHours(23, 59, 59, 999);
  return { from, to };
}

// ---------------------------------------------------------------- load

async function load() {
  const { from, to } = periodRange();
  const sameDay = from.toDateString() === to.toDateString();
  const fmt = (d) => d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
  $('xmRange').textContent = sameDay ? fmt(from) : `${fmt(from)} - ${fmt(to)}`;

  const token = ++loadToken;
  const btn = $('xmRefresh');
  btn.disabled = true;
  btn.classList.add('spin');
  if (!allRows.length) $('xmList').innerHTML = '<div class="xm-msg">Asking Xendit...</div>';
  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/xendit-ledger`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({ username: session.username, password: session.password, mode, from: from.toISOString(), to: to.toISOString() })
    });
    const data = await response.json().catch(() => null);
    if (token !== loadToken) return;
    if (response.status === 404) throw new Error('The xendit-ledger Edge Function isn\'t deployed yet.');
    if (!response.ok || !data?.transactions) throw new Error(data?.error || `HTTP ${response.status}`);
    // Xendit sends 'SUCCESSFUL'; same normalizing as xenditLedger.js.
    allRows = data.transactions
      .map((r) => (r.status === 'SUCCESSFUL' ? { ...r, status: 'SUCCESS' } : r))
      .sort((a, b) => new Date(b.created) - new Date(a.created));
    $('xmAvailable').textContent = peso(data.balance?.cash);
    $('xmPending').textContent = peso(data.balance?.holding);
    $('xmTestNote').classList.toggle('hidden', !data.isTest);
    lastLoaded = Date.now();
    $('xmUpdated').innerHTML = `Updated ${new Date().toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}` +
      (data.truncated ? ' · only the newest 2,000 entries - pick a shorter period' : '') +
      ' · <a href="xendit-ledger.html">Full ledger</a>';
    shown = PAGE;
    render();
  } catch (err) {
    if (token !== loadToken) return;
    allRows = [];
    render();
    $('xmList').innerHTML = `<div class="xm-msg error">${esc(err.message)}</div>`;
  } finally {
    if (token === loadToken) {
      btn.disabled = false;
      btn.classList.remove('spin');
    }
  }
}

// ---------------------------------------------------------------- render

function matches(r, q) {
  if (view === 'in' && isOut(r)) return false;
  if (view === 'out' && !isOut(r)) return false;
  if (view === 'fees' && !feeOf(r)) return false;
  if (!q) return true;
  return [r.id, r.reference_id, r.channel_code, typeLabel(r.type), r.account, r.ours?.order_ref, r.ours?.online_order_id,
    r.ours?.receipt_no, r.ours?.pos_receipt_no, r.ours?.driver, r.ours?.cashier, String(r.amount)]
    .some((v) => v && String(v).toLowerCase().includes(q));
}

function render() {
  // Tiles: the whole period's Success totals (not the tab), like the desktop cues.
  const ok = allRows.filter(isOk);
  const ins = ok.filter((r) => !isOut(r));
  const outs = ok.filter(isOut);
  const sum = (rows, fn) => rows.reduce((s, r) => s + (Number(fn(r)) || 0), 0);
  $('xmIn').textContent = peso(sum(ins, (r) => r.amount));
  $('xmInSub').textContent = `${ins.length} payment${ins.length === 1 ? '' : 's'}`;
  $('xmOut').textContent = peso(sum(outs, (r) => r.amount));
  $('xmOutSub').textContent = `${outs.length} withdrawal${outs.length === 1 ? '' : 's'} / refund${outs.length === 1 ? '' : 's'}`;
  $('xmFees').textContent = peso(sum(ok, feeOf));
  $('xmNet').textContent = peso(sum(ins, netOf));

  document.querySelectorAll('#xmTabs button').forEach((b) => b.classList.toggle('on', b.dataset.view === view));
  document.querySelectorAll('.xm-tile').forEach((b) => b.classList.toggle('on', view !== 'all' && b.dataset.view === view));

  const q = $('xmSearch').value.trim().toLowerCase();
  viewRows = allRows.filter((r) => matches(r, q));
  if (!viewRows.length) {
    $('xmList').innerHTML = `<div class="xm-msg">${allRows.length ? 'Nothing matches.' : 'No Xendit entries in this period.'}</div>`;
    return;
  }

  // Grouped by day, newest first, each day with its net.
  const groups = [];
  viewRows.slice(0, shown).forEach((r) => {
    const key = new Date(r.created).toDateString();
    let g = groups[groups.length - 1];
    if (!g || g.key !== key) groups.push(g = { key, rows: [] });
    g.rows.push(r);
  });
  const dayNet = (key) => viewRows.filter((r) => isOk(r) && new Date(r.created).toDateString() === key)
    .reduce((s, r) => s + (isOut(r) ? -Number(r.amount || 0) : netOf(r)), 0);
  const today = new Date().toDateString();
  const yesterday = new Date(Date.now() - 864e5).toDateString();

  $('xmList').innerHTML = groups.map((g) => {
    const label = g.key === today ? 'Today' : g.key === yesterday ? 'Yesterday'
      : new Date(g.key).toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' });
    const net = dayNet(g.key);
    return `<div class="xm-day"><span>${esc(label)}</span><span>Net ${net < 0 ? '-' : ''}${peso(Math.abs(net))}</span></div>
      <div class="xm-list">${g.rows.map(itemHtml).join('')}</div>`;
  }).join('') + (viewRows.length > shown
    ? `<button type="button" class="xm-more" id="xmMore">Show more (${viewRows.length - shown} left)</button>` : '');
}

function itemHtml(r) {
  const out = isOut(r);
  const o = r.ours;
  const title = o?.order_ref || typeLabel(r.type);
  const who = o ? [SOURCE_LABELS[o.source] || o.source, o.cashier || o.driver].filter(Boolean).join(' · ') : '';
  const sub = [new Date(r.created).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }), r.channel_code, who || (o ? '' : typeLabel(r.type))]
    .filter(Boolean).join(' · ');
  const fee = feeOf(r);
  const status = isOk(r) ? settlementLabel(r) : statusLabel(r.status);
  return `<button type="button" class="xm-item${r.status === 'FAILED' || r.status === 'VOIDED' ? ' dim' : ''}" data-id="${esc(r.id)}">
      <span class="xm-dot ${out ? 'out' : 'in'}">${out ? '↑' : '↓'}</span>
      <span class="xm-main"><div class="t">${esc(title)}</div><div class="s">${esc(sub)}</div></span>
      <span class="xm-amt"><div class="a ${out ? 'out' : 'in'}">${out ? '-' : '+'}${amount(r.amount)}</div>
        ${fee ? `<div class="f">fee ${amount(fee)}</div>` : ''}${status ? `<div class="st">${esc(status)}</div>` : ''}</span>
    </button>`;
}

// ---------------------------------------------------------------- details sheet

function openSheet(id) {
  const r = allRows.find((x) => x.id === id);
  if (!r) return;
  const out = isOut(r);
  const o = r.ours;
  const facts = (list) => '<dl>' + list.filter(([, v]) => v !== '' && v != null)
    .map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('') + '</dl>';
  const fee = feeOf(r);
  const actions = [];
  if (o?.order_ref && o.source !== 'POS') actions.push(`<a href="pay.html?order=${encodeURIComponent(o.order_ref)}" target="_blank" rel="noopener">Show Order</a>`);
  if (o?.receipt_no && o.source !== 'POS' && o.source !== 'Delivery') actions.push(`<a href="payment-receipt.html?id=${encodeURIComponent(o.payment_id)}" target="_blank" rel="noopener">Receipt</a>`);
  actions.push('<button type="button" data-close-sheet>Close</button>');

  $('xmSheet').innerHTML = `<div class="xm-grab"></div>
    <h2 style="color:var(${out ? '--xm-out' : '--xm-in'})">${out ? '-' : '+'}${peso(r.amount)}</h2>
    <div class="sub">${esc(typeLabel(r.type))} · ${esc(statusLabel(r.status))} · ${esc(new Date(r.created).toLocaleString())}</div>
    ${facts([
      ['Xendit Fee', r.xendit_fee ? peso(r.xendit_fee) : ''],
      ['VAT', r.vat ? peso(r.vat) : ''],
      ['Fees + VAT', fee ? peso(fee) : ''],
      ['Withholding Tax', r.withholding_tax ? peso(r.withholding_tax) : ''],
      ['Net Amount', r.net_amount != null ? peso(r.net_amount) : ''],
      ['Settlement', settlementLabel(r)],
      ['Channel', [r.channel_code, (r.channel_category || '').replace(/_/g, ' ').toLowerCase()].filter(Boolean).join(' - ')],
      ['Account', r.account],
      ['Reference', r.reference_id],
      ['Xendit ID', r.id]
    ])}
    ${o ? `<h3>Our order</h3>${facts([
      ['Order No.', o.order_ref],
      ['Online Order ID', o.online_order_id && o.online_order_id !== o.order_ref ? o.online_order_id : ''],
      ['Source', SOURCE_LABELS[o.source] || o.source],
      ['Purpose', o.source === 'Online' ? o.purpose : ''],
      ['Driver', o.driver],
      ['Cashier', o.cashier],
      ['Receipt', o.receipt_no || o.pos_receipt_no]
    ])}` : ''}
    <div class="actions">${actions.join('')}</div>`;
  $('xmSheet').classList.remove('hidden');
  $('xmSheetBg').classList.remove('hidden');
}

function closeSheet() {
  $('xmSheet').classList.add('hidden');
  $('xmSheetBg').classList.add('hidden');
}

// ---------------------------------------------------------------- init

function gate(text) {
  $('xmGate').classList.remove('hidden');
  $('xmGateText').textContent = text;
  $('xmGateBtn').addEventListener('click', logout);
}

(async function init() {
  $('xmLogout').addEventListener('click', logout);
  session = await requireAuth();
  if (!session) return;
  $('xmWho').textContent = session.displayName || session.username || '';

  if (!session.isSuperUser) return gate('The Xendit app is for super users only.');
  if (!session.password) return gate('Please log out and log back in to view Xendit.');

  $('xmApp').classList.remove('hidden');
  mode = recall(MODE_KEY) === 'test' ? 'test' : 'live';
  const savedPeriod = recall(PERIOD_KEY);
  if (['today', 'yesterday', '7d', 'month', 'lastmonth'].includes(savedPeriod)) period = savedPeriod;
  document.querySelectorAll('#xmMode button').forEach((b) => b.classList.toggle('on', b.dataset.mode === mode));
  document.querySelectorAll('#xmPeriods button').forEach((b) => b.classList.toggle('on', b.dataset.period === period));

  $('xmMode').addEventListener('click', (e) => {
    const b = e.target.closest('[data-mode]');
    if (!b || b.dataset.mode === mode) return;
    mode = b.dataset.mode;
    store(MODE_KEY, mode);
    document.querySelectorAll('#xmMode button').forEach((x) => x.classList.toggle('on', x === b));
    allRows = [];
    load();
  });
  $('xmPeriods').addEventListener('click', (e) => {
    const b = e.target.closest('[data-period]');
    if (!b || b.dataset.period === period) return;
    period = b.dataset.period;
    store(PERIOD_KEY, period);
    document.querySelectorAll('#xmPeriods button').forEach((x) => x.classList.toggle('on', x === b));
    allRows = [];
    load();
  });
  $('xmRefresh').addEventListener('click', load);

  const setView = (v) => { view = v; shown = PAGE; render(); };
  $('xmTabs').addEventListener('click', (e) => { const b = e.target.closest('[data-view]'); if (b) setView(b.dataset.view); });
  document.querySelectorAll('.xm-tile').forEach((t) => t.addEventListener('click', () =>
    setView(view === t.dataset.view ? 'all' : t.dataset.view)));
  $('xmSearch').addEventListener('input', () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => { shown = PAGE; render(); }, 200);
  });

  $('xmList').addEventListener('click', (e) => {
    if (e.target.closest('#xmMore')) { shown += PAGE; render(); return; }
    const item = e.target.closest('[data-id]');
    if (item) openSheet(item.dataset.id);
  });
  $('xmSheetBg').addEventListener('click', closeSheet);
  $('xmSheet').addEventListener('click', (e) => { if (e.target.closest('[data-close-sheet]')) closeSheet(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeSheet(); });

  // Coming back to the app (switching from another app / unlocking the phone) refreshes if it's been a minute.
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && Date.now() - lastLoaded > 60000) load();
  });

  load();
})();
