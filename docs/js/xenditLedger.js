// Xendit Ledger Entries (super users only) - Business Central-style list of the Xendit account: balance cues,
// then every transaction in a date range (money in, fees / VAT, money out) from Edge Function xendit-ledger
// (Xendit's Balance + Transactions APIs). Read-only. Payments made through the portal show their order
// (matched to XenditPayments). Layout follows Item Ledger Entries (css/bc-list.css .bc-ile).
let currentSession = null;
let allRows = [];          // everything Xendit returned for the mode + dates
let viewRows = [];         // after the tab / filter pane / search
let ledgerIsTest = false;
let activeView = 'all';    // all / in / out / fees
let selectedId = null;
let page = 1;
let pageSize = 50;
let searchTimer = null;
let filterPaneOpen = window.innerWidth >= 1700; // BC opens lists with the pane closed unless there's room
let loadToken = 0;

function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// BC shows plain numbers in the grid (no currency sign); the cues carry the peso sign.
function amount(value) {
  return value == null ? '' : Number(value).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function peso(value) {
  return value == null ? '-' : '₱' + amount(value);
}

function dateInput(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function formatDate(value) {
  return value ? new Date(value).toLocaleDateString() : '';
}

const TYPE_LABELS = {
  PAYMENT: 'Payment', DISBURSEMENT: 'Disbursement', BATCH_DISBURSEMENT: 'Disbursement', WITHDRAWAL: 'Withdrawal',
  REFUND: 'Refund', TRANSFER: 'Transfer', TOPUP: 'Top Up', REMITTANCE_PAYOUT: 'Payout', REMITTANCE: 'Remittance'
};
const SOURCE_LABELS = { Online: 'Pay link', POS: 'POS', Delivery: 'Delivery QR' };

function typeLabel(t) {
  return TYPE_LABELS[t] || String(t || '').replace(/_/g, ' ').toLowerCase().replace(/\b\w/g, (c) => c.toUpperCase());
}

function statusLabel(s) {
  return String(s || '').charAt(0) + String(s || '').slice(1).toLowerCase();
}

function feeOf(r) {
  return (Number(r.xendit_fee) || 0) + (Number(r.vat) || 0);
}

function isOut(r) {
  return r.cashflow === 'MONEY_OUT';
}

// Signed like a ledger: money out is negative.
function signedAmount(r) {
  return (isOut(r) ? -1 : 1) * (Number(r.amount) || 0);
}

function signedNet(r) {
  const net = r.net_amount != null ? Number(r.net_amount) : (Number(r.amount) || 0) - feeOf(r);
  return (isOut(r) ? -1 : 1) * net;
}

function settlementLabel(r) {
  if (isOut(r) || !r.settlement_status || r.status !== 'SUCCESS') return '';
  if (r.settlement_status === 'SETTLED' || r.settlement_status === 'EARLY_SETTLED') return 'Settled';
  return r.estimated_settlement ? `Due ${new Date(r.estimated_settlement).toLocaleDateString()}` : 'Pending';
}

function selectedRow() {
  return viewRows.find((r) => r.id === selectedId) || null;
}

function modeValue() {
  return document.querySelector('input[name="xlMode"]:checked').value;
}

// ---------------------------------------------------------------- layout

function fitGrid() {
  const el = document.getElementById('xlGridWrap');
  const top = el.getBoundingClientRect().top;
  el.style.maxHeight = Math.max(240, window.innerHeight - top - 56) + 'px'; // room for the pagination bar
}

function updateBodyLayout() {
  document.getElementById('bcBody').classList.toggle('no-filterpane', !filterPaneOpen);
  document.getElementById('filterPane').classList.toggle('hidden', !filterPaneOpen);
  document.getElementById('filterPaneBtn').setAttribute('aria-pressed', filterPaneOpen ? 'true' : 'false');
  fitGrid();
}

function setInfobar(html) {
  document.getElementById('xlInfobar').classList.toggle('hidden', !html);
  document.getElementById('xlInfobarText').innerHTML = html || '';
}

function applyPeriod() {
  const period = document.getElementById('xlPeriod').value;
  if (period === 'custom') return;
  const now = new Date();
  let from = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  let to = new Date(from);
  if (period === '7d') from.setDate(from.getDate() - 6);
  if (period === 'month') from = new Date(now.getFullYear(), now.getMonth(), 1);
  if (period === 'lastmonth') {
    from = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    to = new Date(now.getFullYear(), now.getMonth(), 0);
  }
  document.getElementById('xlFromDate').value = dateInput(from);
  document.getElementById('xlToDate').value = dateInput(to);
}

// ---------------------------------------------------------------- loading from Xendit

async function loadLedger() {
  const fromValue = document.getElementById('xlFromDate').value;
  const toValue = document.getElementById('xlToDate').value;
  const body = document.getElementById('xlTableBody');
  if (!fromValue || !toValue) {
    body.innerHTML = '<tr><td colspan="12" class="cell-msg">Enter both Posting Date filters.</td></tr>';
    return;
  }
  const from = new Date(`${fromValue}T00:00:00`);
  const to = new Date(`${toValue}T23:59:59.999`);
  const token = ++loadToken;
  body.innerHTML = '<tr><td colspan="12" class="cell-msg">Asking Xendit...</td></tr>';
  document.getElementById('xlRefreshBtn').disabled = true;
  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/xendit-ledger`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        username: currentSession.username,
        password: currentSession.password,
        mode: modeValue(),
        from: from.toISOString(),
        to: to.toISOString()
      })
    });
    const data = await response.json().catch(() => null);
    if (token !== loadToken) return; // a newer load started meanwhile
    if (response.status === 404) throw new Error('The xendit-ledger Edge Function isn\'t deployed yet.');
    if (!response.ok || !data?.transactions) throw new Error(data?.error || `HTTP ${response.status}`);
    allRows = data.transactions;
    ledgerIsTest = data.isTest;
    fillFilterOptions();
    renderBalance(data.balance);
    setInfobar([
      data.isTest ? '<strong>TEST mode</strong> - test payments only, no real money.' : '',
      data.truncated ? 'Only the newest 2,000 entries are shown - narrow the Posting Date filter.' : ''
    ].filter(Boolean).join(' '));
    page = 1;
    applyFilters();
  } catch (err) {
    if (token !== loadToken) return;
    allRows = [];
    viewRows = [];
    renderBalance(null);
    renderCues();
    body.innerHTML = `<tr><td colspan="12" class="cell-msg error-text">${esc(err.message)}</td></tr>`;
    renderTotals();
    document.getElementById('xlPaginationBar').innerHTML = '';
    renderFactBox();
  } finally {
    if (token === loadToken) document.getElementById('xlRefreshBtn').disabled = false;
  }
}

// Entry Type / Channel options from what's loaded, keeping the current pick.
function fillFilterOptions() {
  const fill = (id, values, label) => {
    const sel = document.getElementById(id);
    const current = sel.value;
    const unique = [...new Set(values.filter(Boolean))].sort();
    if (current && !unique.includes(current)) unique.push(current);
    sel.innerHTML = '<option value="">(all)</option>' + unique.map((v) => `<option value="${esc(v)}">${esc(label(v))}</option>`).join('');
    sel.value = current;
  };
  fill('xlTypeFilter', allRows.map((r) => r.type), typeLabel);
  fill('xlChannelFilter', allRows.map((r) => r.channel_code), (v) => v);
}

function renderBalance(balance) {
  document.getElementById('cueAvailable').textContent = peso(balance?.cash);
  document.getElementById('cuePending').textContent = peso(balance?.holding);
}

// ---------------------------------------------------------------- filtering + grid

function filterValues() {
  return {
    type: document.getElementById('xlTypeFilter').value,
    status: document.getElementById('xlStatusFilter').value,
    channel: document.getElementById('xlChannelFilter').value,
    source: document.getElementById('xlSourceFilter').value,
    q: document.getElementById('xlSearchInput').value.trim().toLowerCase()
  };
}

function matches(r, f) {
  if (activeView === 'in' && isOut(r)) return false;
  if (activeView === 'out' && !isOut(r)) return false;
  if (activeView === 'fees' && !feeOf(r)) return false;
  if (f.type && r.type !== f.type) return false;
  if (f.status && r.status !== f.status) return false;
  if (f.channel && r.channel_code !== f.channel) return false;
  if (f.source === 'none' && r.ours) return false;
  if (f.source && f.source !== 'none' && r.ours?.source !== f.source) return false;
  if (!f.q) return true;
  return [r.id, r.reference_id, r.channel_code, r.channel_category, typeLabel(r.type), r.account, r.ours?.order_ref,
    r.ours?.online_order_id, r.ours?.receipt_no, r.ours?.pos_receipt_no, r.ours?.driver, r.ours?.cashier]
    .some((v) => v && String(v).toLowerCase().includes(f.q));
}

function applyFilters() {
  const f = filterValues();
  viewRows = allRows.filter((r) => matches(r, f));
  if (!viewRows.some((r) => r.id === selectedId)) selectedId = null;
  renderChips();
  renderCues();
  renderGrid();
  renderTotals();
  renderFactBox();
  updateActionState();
}

// Cues: the period's Success totals across everything loaded (not the tab), so they stay put while you
// click around. Money In / Fees / Money Out switch the tab, like a BC cue drilling into its entries.
function renderCues() {
  const ok = allRows.filter((r) => r.status === 'SUCCESS');
  const ins = ok.filter((r) => !isOut(r));
  const outs = ok.filter(isOut);
  const sum = (rows, fn) => rows.reduce((s, r) => s + (Number(fn(r)) || 0), 0);
  document.getElementById('cueIn').textContent = allRows.length ? peso(sum(ins, (r) => r.amount)) : '-';
  document.getElementById('cueInNote').textContent = `${ins.length} payment${ins.length === 1 ? '' : 's'}`;
  document.getElementById('cueFees').textContent = allRows.length ? peso(sum(ok, feeOf)) : '-';
  document.getElementById('cueNet').textContent = allRows.length ? peso(sum(ins, signedNet)) : '-';
  document.getElementById('cueOut').textContent = allRows.length ? peso(sum(outs, (r) => r.amount)) : '-';
  document.getElementById('cueOutNote').textContent = `${outs.length} withdrawal${outs.length === 1 ? '' : 's'} / refund${outs.length === 1 ? '' : 's'}`;
  document.querySelectorAll('[data-cue-view]').forEach((cue) => cue.classList.toggle('active', cue.dataset.cueView === activeView));
}

function renderChips() {
  const chips = [];
  const from = document.getElementById('xlFromDate').value;
  const to = document.getElementById('xlToDate').value;
  chips.push({ key: 'mode', label: 'Mode: ' + (modeValue() === 'test' ? 'Test' : 'Live'), fixed: true });
  if (from || to) chips.push({ key: 'date', label: `Posting Date: ${from ? formatDate(from + 'T00:00') : '...'}..${to ? formatDate(to + 'T00:00') : '...'}`, fixed: true });
  const f = filterValues();
  if (f.type) chips.push({ key: 'type', label: 'Entry Type: ' + typeLabel(f.type) });
  if (f.status) chips.push({ key: 'status', label: 'Status: ' + statusLabel(f.status) });
  if (f.channel) chips.push({ key: 'channel', label: 'Channel: ' + f.channel });
  if (f.source) chips.push({ key: 'source', label: 'Source: ' + (f.source === 'none' ? 'Not from the portal' : SOURCE_LABELS[f.source]) });
  const box = document.getElementById('filterChips');
  box.classList.remove('hidden');
  box.innerHTML = '<span class="muted">Filtered by:</span>' + chips.map((c) =>
    `<span class="bc-chip">${esc(c.label)}${c.fixed ? '' : `<button type="button" data-clear-filter="${c.key}" aria-label="Remove this filter">&times;</button>`}</span>`).join('');
}

function sourceCell(r) {
  if (!r.ours) return '';
  const extra = r.ours.source === 'Delivery' ? r.ours.driver : r.ours.source === 'POS' ? r.ours.cashier : r.ours.purpose;
  return esc(SOURCE_LABELS[r.ours.source] || r.ours.source || '') + (extra ? ` <span class="muted">· ${esc(extra)}</span>` : '');
}

function renderGrid() {
  const body = document.getElementById('xlTableBody');
  if (!viewRows.length) {
    body.innerHTML = `<tr><td colspan="12" class="cell-msg">${allRows.length ? 'There is nothing to show for these filters.' : 'There are no Xendit entries in this period.'}</td></tr>`;
    document.getElementById('xlPaginationBar').innerHTML = '';
    fitGrid();
    return;
  }
  const pages = Math.max(1, Math.ceil(viewRows.length / pageSize));
  if (page > pages) page = pages;
  const rows = viewRows.slice((page - 1) * pageSize, page * pageSize);

  body.innerHTML = rows.map((r) => {
    const amt = signedAmount(r);
    const net = signedNet(r);
    const fee = feeOf(r);
    // Failed / voided entries never moved money - dimmed like a reversed entry on Item Ledger Entries.
    const classes = [r.status === 'FAILED' || r.status === 'VOIDED' ? 'dim' : '', r.id === selectedId ? 'selected' : ''].filter(Boolean).join(' ');
    const order = r.ours ? (r.ours.order_ref || '') : '';
    return `
      <tr class="${classes}" data-id="${esc(r.id)}">
        <td>${esc(formatDate(r.created))}</td>
        <td>${esc(new Date(r.created).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }))}</td>
        <td>${esc(typeLabel(r.type))}</td>
        <td>${esc(r.channel_code || '')}</td>
        <td>${order ? `<button type="button" class="bc-link" data-drill-order="${esc(order)}" title="Show only this order's entries">${esc(order)}</button>` : ''}</td>
        <td class="cell-text">${sourceCell(r)}</td>
        <td class="cell-text" title="${esc(r.reference_id || '')}">${esc(r.reference_id || '')}</td>
        <td class="num${amt < 0 ? ' neg' : ''}">${amount(amt)}</td>
        <td class="num">${fee ? amount(fee) : ''}</td>
        <td class="num${net < 0 ? ' neg' : ''}">${amount(net)}</td>
        <td class="xl-status-${esc(r.status)}">${esc(statusLabel(r.status))}</td>
        <td>${esc(settlementLabel(r))}</td>
      </tr>`;
  }).join('');

  renderPaginationBar(
    document.getElementById('xlPaginationBar'),
    { page, pageSize, totalCount: viewRows.length },
    {
      onPageChange: (newPage) => { page = newPage; renderGrid(); },
      onPageSizeChange: (newSize) => { pageSize = newSize; page = 1; renderGrid(); }
    }
  );
  fitGrid();
}

// Footer: Success entries in the filtered list (all pages), signed.
function renderTotals() {
  const ok = viewRows.filter((r) => r.status === 'SUCCESS');
  const sum = (fn) => ok.reduce((s, r) => s + (Number(fn(r)) || 0), 0);
  const set = (id, v) => {
    const el = document.getElementById(id);
    el.textContent = amount(v);
    el.classList.toggle('neg', v < 0);
  };
  set('xlTotalAmount', sum(signedAmount));
  set('xlTotalFees', sum(feeOf));
  set('xlTotalNet', sum(signedNet));
}

// ---------------------------------------------------------------- selection + FactBox

function selectRow(id) {
  selectedId = id;
  document.querySelectorAll('#xlTableBody tr[data-id]').forEach((tr) => tr.classList.toggle('selected', tr.dataset.id === id));
  renderFactBox();
  updateActionState();
}

function moveSelection(step) {
  if (!viewRows.length) return;
  const idx = viewRows.findIndex((r) => r.id === selectedId);
  const next = idx < 0 ? (step > 0 ? 0 : viewRows.length - 1) : Math.min(Math.max(idx + step, 0), viewRows.length - 1);
  const targetPage = Math.floor(next / pageSize) + 1;
  if (targetPage !== page) {
    page = targetPage;
    selectedId = viewRows[next].id;
    renderGrid();
  }
  selectRow(viewRows[next].id);
  const tr = document.querySelector(`#xlTableBody tr[data-id="${CSS.escape(viewRows[next].id)}"]`);
  if (tr) tr.scrollIntoView({ block: 'nearest' });
}

function factList(facts) {
  return '<dl class="bc-facts">' + facts
    .filter(([, v]) => v !== '' && v !== null && v !== undefined)
    .map(([k, v, html]) => `<dt>${esc(k)}</dt><dd>${html ? v : esc(v)}</dd>`).join('') + '</dl>';
}

function renderFactBox() {
  const details = document.getElementById('factDetails');
  const orderBox = document.getElementById('factOrderBox');
  const r = selectedRow();
  if (!r) {
    details.innerHTML = '<p class="bc-fact-empty">Select an entry to see its details.</p>';
    orderBox.classList.add('hidden');
    return;
  }
  details.innerHTML = factList([
    ['Entry Type', typeLabel(r.type)],
    ['Direction', isOut(r) ? 'Money out' : 'Money in'],
    ['Status', statusLabel(r.status)],
    ['Posted At', new Date(r.created).toLocaleString()],
    ['Channel', [r.channel_code, (r.channel_category || '').replace(/_/g, ' ').toLowerCase()].filter(Boolean).join(' - ')],
    ['Account', r.account],
    ['Amount', peso(r.amount)],
    ['Xendit Fee', r.xendit_fee ? peso(r.xendit_fee) : ''],
    ['VAT', r.vat ? peso(r.vat) : ''],
    ['Withholding Tax', r.withholding_tax ? peso(r.withholding_tax) : ''],
    ['Net Amount', r.net_amount != null ? peso(r.net_amount) : ''],
    ['Settlement', settlementLabel(r)],
    ['Reference', r.reference_id],
    ['Xendit ID', r.id]
  ]);

  const o = r.ours;
  orderBox.classList.toggle('hidden', !o);
  if (!o) return;
  const receipt = o.receipt_no && o.source !== 'POS' && o.source !== 'Delivery'
    ? `<a class="bc-link" href="payment-receipt.html?id=${encodeURIComponent(o.payment_id)}" target="_blank" rel="noopener">${esc(o.receipt_no)}</a>`
    : esc(o.receipt_no || o.pos_receipt_no || '');
  document.getElementById('factOrder').innerHTML = factList([
    ['Order No.', o.order_ref],
    ['Online Order ID', o.online_order_id && o.online_order_id !== o.order_ref ? o.online_order_id : ''],
    ['Source', SOURCE_LABELS[o.source] || o.source],
    ['Purpose', o.source === 'Online' ? o.purpose : ''],
    ['Driver', o.driver],
    ['Cashier', o.cashier],
    ['POS Receipt No.', o.source === 'POS' ? o.pos_receipt_no : ''],
    ['Receipt', receipt, true]
  ]);
}

function canShowReceipt(r) {
  return !!(r?.ours?.receipt_no && r.ours.source !== 'POS' && r.ours.source !== 'Delivery');
}

function canShowOrder(r) {
  return !!(r?.ours?.order_ref && r.ours.source !== 'POS');
}

function updateActionState() {
  const r = selectedRow();
  document.getElementById('xlReceiptBtn').disabled = !canShowReceipt(r);
  document.getElementById('xlPayLinkBtn').disabled = !canShowOrder(r);
  document.getElementById('xlCsvBtn').disabled = !viewRows.length;
}

// ---------------------------------------------------------------- tabs, filters, export

function setView(view) {
  activeView = view;
  document.querySelectorAll('.bc-tab').forEach((tab) => {
    const on = tab.dataset.view === view;
    tab.classList.toggle('active', on);
    tab.setAttribute('aria-selected', on ? 'true' : 'false');
  });
  page = 1;
  applyFilters();
}

function clearOneFilter(key) {
  const ids = { type: 'xlTypeFilter', status: 'xlStatusFilter', channel: 'xlChannelFilter', source: 'xlSourceFilter' };
  if (ids[key]) document.getElementById(ids[key]).value = '';
  page = 1;
  applyFilters();
}

// Clears what works on the loaded list; Mode and Period stay (they decide what's asked from Xendit).
function clearFilters() {
  ['xlTypeFilter', 'xlStatusFilter', 'xlChannelFilter', 'xlSourceFilter', 'xlSearchInput'].forEach((id) => { document.getElementById(id).value = ''; });
  page = 1;
  setView('all');
}

function downloadCsv() {
  if (!viewRows.length) return;
  const cell = (v) => {
    const s = String(v ?? '');
    return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const header = ['Posting Date', 'Time', 'Entry Type', 'Direction', 'Status', 'Settlement', 'Channel', 'Category', 'Order No.', 'Source',
    'Purpose', 'Receipt', 'Reference', 'Amount', 'Xendit Fee', 'VAT', 'Withholding Tax', 'Net Amount', 'Xendit ID'];
  const lines = viewRows.map((r) => [
    formatDate(r.created), new Date(r.created).toLocaleTimeString(), typeLabel(r.type), isOut(r) ? 'Out' : 'In', statusLabel(r.status),
    settlementLabel(r), r.channel_code, r.channel_category, r.ours?.order_ref, r.ours ? (SOURCE_LABELS[r.ours.source] || r.ours.source) : '',
    r.ours?.purpose, r.ours?.receipt_no || r.ours?.pos_receipt_no, r.reference_id,
    signedAmount(r).toFixed(2), Number(r.xendit_fee || 0).toFixed(2), Number(r.vat || 0).toFixed(2), Number(r.withholding_tax || 0).toFixed(2),
    signedNet(r).toFixed(2), r.id
  ].map(cell).join(','));
  const blob = new Blob(['﻿' + [header.join(','), ...lines].join('\r\n')], { type: 'text/csv;charset=utf-8' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `xendit-ledger-${ledgerIsTest ? 'test-' : ''}${document.getElementById('xlFromDate').value}-to-${document.getElementById('xlToDate').value}.csv`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

// ---------------------------------------------------------------- init

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Xendit Ledger');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }
  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view the Xendit Ledger.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('ledgerContent').classList.remove('hidden');
  applyPeriod();

  // Asked from Xendit again: mode, period, dates, Refresh.
  document.querySelectorAll('input[name="xlMode"]').forEach((el) => el.addEventListener('change', loadLedger));
  document.getElementById('xlPeriod').addEventListener('change', () => { applyPeriod(); loadLedger(); });
  ['xlFromDate', 'xlToDate'].forEach((id) => document.getElementById(id).addEventListener('change', () => {
    document.getElementById('xlPeriod').value = 'custom';
    loadLedger();
  }));
  document.getElementById('xlRefreshBtn').addEventListener('click', loadLedger);

  // Work on what's loaded.
  ['xlTypeFilter', 'xlStatusFilter', 'xlChannelFilter', 'xlSourceFilter'].forEach((id) =>
    document.getElementById(id).addEventListener('change', () => { page = 1; applyFilters(); }));
  document.getElementById('xlSearchInput').addEventListener('input', () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => { page = 1; applyFilters(); }, 250);
  });
  document.querySelectorAll('.bc-tab').forEach((tab) => tab.addEventListener('click', () => setView(tab.dataset.view)));
  document.querySelectorAll('[data-cue-view]').forEach((cue) => cue.addEventListener('click', () =>
    setView(activeView === cue.dataset.cueView ? 'all' : cue.dataset.cueView)));
  document.getElementById('filterChips').addEventListener('click', (event) => {
    const btn = event.target.closest('[data-clear-filter]');
    if (btn) clearOneFilter(btn.dataset.clearFilter);
  });
  document.getElementById('clearFiltersBtn').addEventListener('click', clearFilters);
  document.getElementById('clearFiltersLink').addEventListener('click', clearFilters);
  document.getElementById('filterPaneBtn').addEventListener('click', () => {
    filterPaneOpen = !filterPaneOpen;
    updateBodyLayout();
  });

  // Grid: select a row, or drill into an order's entries (BC's drill-down).
  document.getElementById('xlTableBody').addEventListener('click', (event) => {
    const drill = event.target.closest('[data-drill-order]');
    if (drill) {
      document.getElementById('xlSearchInput').value = drill.dataset.drillOrder;
      page = 1;
      applyFilters();
      return;
    }
    const row = event.target.closest('tr[data-id]');
    if (row) selectRow(row.dataset.id);
  });
  document.addEventListener('keydown', (event) => {
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    if (event.target && event.target.closest && event.target.closest('input, select, textarea, button')) return;
    event.preventDefault();
    moveSelection(event.key === 'ArrowDown' ? 1 : -1);
  });

  document.getElementById('xlCsvBtn').addEventListener('click', downloadCsv);
  document.getElementById('xlReceiptBtn').addEventListener('click', () => {
    const r = selectedRow();
    if (canShowReceipt(r)) window.open(`payment-receipt.html?id=${encodeURIComponent(r.ours.payment_id)}`, '_blank', 'noopener');
  });
  document.getElementById('xlPayLinkBtn').addEventListener('click', () => {
    const r = selectedRow();
    if (canShowOrder(r)) window.open(`pay.html?order=${encodeURIComponent(r.ours.order_ref)}`, '_blank', 'noopener');
  });

  let resizeTimer = null;
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(fitGrid, 100);
  });

  updateBodyLayout();
  updateActionState();
  await loadLedger();
})();
