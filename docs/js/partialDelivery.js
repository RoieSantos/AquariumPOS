// Printable Partial Delivery Slip, per "build me a report for an advance order.. they partially send over
// the items.. there will be one more item that left to deliver". The slip lists each item with its status -
// "Included in this Delivery" or "Pending to Deliver" (per "just show the status"); items delivered already
// are left off (per "dont print the once that is delivered already").
//   ?order=<OnlineOrders.OrderID>[&batch=<n>] - from the Dispatcher's release batches (no batch = latest).
//       An order never released in batches (e.g. already Delivered) falls back to the editor.
//   ?advance=<AdvanceOrders.TransactionNo>     - POS Advance Orders have no partial release: the editor.
// Editor (not printed): a Status per line, or split quantities. Not saved to the database; remembered in this
// browser per order so the next delivery's slip starts from it. Opened from the "Delivery Slip" button on the
// Online Order / Advance Order documents, the Print button per batch in Release History, and after a partial
// release. Data: sql/supabase_online_order_partial_delivery_slip.sql.
let currentSession = null;
// { key, manual, lines: [{ line_no, description, line_note, ordered, before, now }] }
// before = delivered already, now = in this delivery, pending = ordered - before - now.
let slip = null;

const ST_NOW = 'Included in this Delivery';
const ST_PENDING = 'Pending to Deliver';

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function formatMoney(value) {
  return `₱ ${Number(value || 0).toFixed(2)}`;
}

function formatQty(value) {
  const n = Number(value || 0);
  return Number.isInteger(n) ? String(n) : n.toFixed(2);
}

function formatDate(dateStr) {
  if (!dateStr) return '';
  const d = new Date(`${String(dateStr).slice(0, 10)}T00:00:00`);
  if (Number.isNaN(d.getTime())) return dateStr;
  return `${String(d.getDate()).padStart(2, '0')}/${String(d.getMonth() + 1).padStart(2, '0')}/${d.getFullYear()}`;
}

function formatDateTime(ts) {
  if (!ts) return '';
  return new Date(ts).toLocaleString([], { day: '2-digit', month: 'short', year: 'numeric', hour: 'numeric', minute: '2-digit' });
}

function setText(id, text) {
  document.getElementById(id).textContent = text || '';
}

function pendingOf(l) {
  return Math.max(l.ordered - l.before - l.now, 0);
}

function renderCompanyHeader(info) {
  if (!info) return;
  const logo = document.getElementById('receiptLogo');
  if (info['LogoUrl']) {
    logo.src = info['LogoUrl'];
    logo.classList.remove('hidden');
  }
  setText('receiptCompanyName', info['CompanyName']);
  setText('receiptFacebook', info['FacebookUrl']);
  setText('receiptAddress', info['Address'] ? `Address : ${info['Address']}` : '');
  setText('receiptContactNo', info['ContactNo'] ? `Contact No : ${info['ContactNo']}` : '');
}

function showError(message) {
  const el = document.getElementById('loadError');
  el.textContent = message;
  el.classList.remove('hidden');
  document.getElementById('receiptContent').classList.add('hidden');
  document.getElementById('manualBar').classList.add('hidden');
  document.getElementById('printBtn').disabled = true;
}

// ---------------------------------------------------------------- the printed slip
// One row per status: a line split between this delivery and pending prints as two rows.
function renderSlip() {
  const rows = [];
  slip.lines.forEach((l) => {
    if (l.now > 0) rows.push({ l, qty: l.now, pending: false });
    const p = pendingOf(l);
    if (p > 0) rows.push({ l, qty: p, pending: true });
  });
  rows.sort((a, b) => (a.pending - b.pending) || (a.l.line_no - b.l.line_no));

  document.getElementById('slipLinesBody').innerHTML = rows.length
    ? rows.map((r, i) => `
      <tr>
        <td>${i + 1}</td>
        <td>${escapeHtml(r.l.description)}${r.l.line_note ? `<div class="delivery-receipt-line-note">Note: ${escapeHtml(r.l.line_note)}</div>` : ''}</td>
        <td class="num">${formatQty(r.qty)}</td>
        <td class="pd-st ${r.pending ? 'pd-st-pending' : ''}">${r.pending ? ST_PENDING : ST_NOW}</td>
      </tr>`).join('')
    : '<tr><td colspan="4" class="muted">No items in this delivery - pick a Status above.</td></tr>';

  const pendingUnits = slip.lines.reduce((n, l) => n + pendingOf(l), 0);
  setText('slipStatus', pendingUnits
    ? `Partial delivery - ${formatQty(pendingUnits)} item(s) pending to deliver.`
    : 'Final delivery - this completes the order.');
  setText('slipTitle', pendingUnits ? 'PARTIAL DELIVERY SLIP' : 'DELIVERY SLIP - FINAL');
}

// ---------------------------------------------------------------- editor (not printed)
function lineStatus(l) {
  if (l.before >= l.ordered) return 'before';
  if (l.now > 0 && pendingOf(l) === 0) return 'now';
  if (l.now === 0) return 'pending';
  return 'split';
}

function applyStatus(l, status) {
  if (status === 'now') {
    if (l.before >= l.ordered) l.before = 0; // a "delivered already" line starts over
    l.now = l.ordered - l.before;
  } else if (status === 'pending') {
    if (l.before >= l.ordered) l.before = 0;
    l.now = 0;
  } else if (status === 'before') {
    l.before = l.ordered;
    l.now = 0;
  }
}

function statusSelectHtml(l) {
  const s = lineStatus(l);
  const opt = (v, label) => `<option value="${v}" ${s === v ? 'selected' : ''}>${label}</option>`;
  return `<select class="pd-line-status" data-line="${l.line_no}">
    ${opt('now', ST_NOW)}${opt('pending', ST_PENDING)}${opt('before', 'Delivered already (not printed)')}
    ${s === 'split' ? opt('split', 'Split - see quantities') : ''}
  </select>`;
}

function qtyInput(l, field) {
  return `<input type="number" class="pd-qty" min="0" step="1" data-line="${l.line_no}" data-field="${field}" value="${formatQty(l[field])}" />`;
}

function editorRowHtml(l) {
  return `
    <tr data-line="${l.line_no}" class="${lineStatus(l) === 'before' ? 'pd-done-before' : ''}">
      <td>${statusSelectHtml(l)}</td>
      <td>${l.line_no}</td>
      <td>${escapeHtml(l.description)}</td>
      <td class="num">${formatQty(l.ordered)}</td>
      <td class="num">${qtyInput(l, 'before')}</td>
      <td class="num">${qtyInput(l, 'now')}</td>
      <td class="num pd-left">${formatQty(pendingOf(l))}</td>
    </tr>`;
}

function render() {
  if (slip.manual) document.getElementById('editorBody').innerHTML = slip.lines.map(editorRowHtml).join('');
  renderSlip();
}

function loadSaved(key) {
  try { return JSON.parse(localStorage.getItem(key) || 'null'); } catch { return null; }
}

function saveTyped() {
  if (!slip?.manual) return;
  try {
    localStorage.setItem(slip.key, JSON.stringify({
      delivery_no: document.getElementById('deliveryNoInput').value,
      lines: slip.lines.map((l) => ({ line_no: l.line_no, before: l.before, now: l.now }))
    }));
  } catch { /* storage blocked - editing still works */ }
}

function findLine(el) {
  return slip.lines.find((l) => String(l.line_no) === el.dataset.line);
}

function setDeliveryNo(no) {
  document.getElementById('deliveryNoInput').value = String(no);
  setText('slipBatch', `Delivery #${no}`);
}

function wireEditor() {
  const body = document.getElementById('editorBody');
  body.addEventListener('input', (e) => {
    const input = e.target.closest('.pd-qty');
    if (!input) return;
    const line = findLine(input);
    const other = input.dataset.field === 'before' ? line.now : line.before;
    let v = Math.max(Number(input.value) || 0, 0);
    if (v + other > line.ordered) v = Math.max(line.ordered - other, 0); // never more than ordered
    line[input.dataset.field] = v;
    // Update the row in place (re-rendering would take focus away from the box being typed in).
    const row = input.closest('tr');
    row.querySelector('.pd-left').textContent = formatQty(pendingOf(line));
    row.className = lineStatus(line) === 'before' ? 'pd-done-before' : '';
    row.querySelector('.pd-line-status').outerHTML = statusSelectHtml(line);
    renderSlip();
    saveTyped();
  });
  body.addEventListener('change', (e) => {
    const input = e.target.closest('.pd-qty');
    if (input) {
      input.value = formatQty(findLine(input)[input.dataset.field]); // show the clamped value
      return;
    }
    const sel = e.target.closest('.pd-line-status');
    if (!sel || sel.value === 'split') return;
    applyStatus(findLine(sel), sel.value);
    render();
    saveTyped();
  });

  const bulk = (status) => {
    slip.lines.forEach((l) => { if (l.before < l.ordered) applyStatus(l, status); });
    render();
    saveTyped();
  };
  document.getElementById('allNowBtn').addEventListener('click', () => bulk('now'));
  document.getElementById('allPendingBtn').addEventListener('click', () => bulk('pending'));

  document.getElementById('deliveryNoInput').addEventListener('input', (e) => {
    setText('slipBatch', `Delivery #${e.target.value || 1}`);
    saveTyped();
  });
  // Next delivery: this delivery becomes "delivered already", everything still pending is included.
  document.getElementById('nextDeliveryBtn').addEventListener('click', () => {
    slip.lines.forEach((l) => {
      l.before = Math.min(l.ordered, l.before + l.now);
      l.now = l.ordered - l.before;
    });
    setDeliveryNo((Number(document.getElementById('deliveryNoInput').value) || 1) + 1);
    render();
    saveTyped();
  });
  document.getElementById('clearTypedBtn').addEventListener('click', () => {
    slip.lines.forEach((l) => { l.before = 0; l.now = 0; });
    setDeliveryNo(1);
    render();
    saveTyped();
  });
}

// Editor mode, restoring what was picked last time for this order.
function enterManualMode(key) {
  slip.manual = true;
  slip.key = key;
  const saved = loadSaved(key);
  if (saved?.lines) {
    saved.lines.forEach((s) => {
      const l = slip.lines.find((x) => x.line_no === s.line_no);
      if (!l) return;
      l.before = Math.min(Number(s.before) || 0, l.ordered);
      l.now = Math.min(Number(s.now) || 0, l.ordered - l.before);
    });
  }
  setDeliveryNo(saved?.delivery_no || 1);
  setText('slipReleased', `Date : ${formatDate(new Date().toISOString())}`);
  document.getElementById('manualBar').classList.remove('hidden');
  document.getElementById('batchPickWrap').classList.add('hidden');
}

function showBalance(total, balance, fullyPaid) {
  setText('slipBalance', !fullyPaid && Number(balance) > 0
    ? `Order total ${formatMoney(total)} - Balance ${formatMoney(balance)}`
    : `Order total ${formatMoney(total)} - Fully paid`);
}

// ---------------------------------------------------------------- Online Orders (release batches)
async function loadOnlineSlip(orderId, batchNo) {
  const { data, error } = await supabaseClient.rpc('staff_get_online_order_partial_delivery_slip', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId,
    p_batch_no: batchNo
  });
  if (error) return showError(error.message);
  if (!data || !data.length) return showError('This order has no item lines to print.');

  const h = data[0];
  slip = {
    manual: false,
    lines: data.map((r) => ({
      line_no: r.line_no, description: r.description, line_note: r.line_note,
      ordered: Number(r.ordered_qty), before: Number(r.delivered_before), now: Number(r.this_batch_qty)
    }))
  };

  setText('slipOrderNo', `Order #${h.order_id}`);
  setText('slipAoNo', h.advance_order_no ? `Advance Order : ${h.advance_order_no}` : '');
  setText('slipOrderDate', h.order_date ? `Order date: ${formatDate(h.order_date)}` : '');
  setText('slipLocation', h.warehouse_name ? `Location : ${h.warehouse_name}` : '');
  document.getElementById('slipReceiverName').innerHTML = `Receiver: <strong>${escapeHtml(h.customer_name)}</strong>`;
  setText('slipReceiverAddress', h.shipping_address);
  setText('slipReceiverPhone', h.shipping_phone);
  showBalance(h.money_to_collect, h.balance, Number(h.balance) <= 0);

  if (h.batch_no > 0) {
    setText('slipBatch', `Delivery #${h.batch_no}`);
    setText('slipReleased', `Released : ${formatDateTime(h.released_at)}`);
    setText('slipBatchNote', h.batch_note ? `Note: ${h.batch_note}` : '');
    document.getElementById('slipBatchNote').classList.toggle('hidden', !h.batch_note);
    setText('slipReleasedBySign', `Released by ${h.released_by_name || ''}`);
    const pick = document.getElementById('batchPick');
    pick.innerHTML = Array.from({ length: h.last_batch_no }, (_, i) => i + 1)
      .map((n) => `<option value="${n}" ${n === h.batch_no ? 'selected' : ''}>#${n}</option>`).join('');
    document.getElementById('batchPickWrap').classList.toggle('hidden', h.last_batch_no < 2);
  } else {
    enterManualMode(`pdslip:order:${orderId}`); // never released in batches (e.g. already Delivered)
  }
  finishLoad(h.order_id);
}

// ---------------------------------------------------------------- Advance Orders (editor)
async function loadAdvanceSlip(no) {
  const { data, error } = await supabaseClient.rpc('staff_get_advance_order_delivery_slip', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_no: no
  });
  if (error) return showError(error.message);
  if (!data || !data.length) return showError('This advance order has no item lines to print.');

  const h = data[0];
  slip = {
    manual: false,
    lines: data.map((r) => ({
      line_no: r.line_no, description: r.description, line_note: null,
      ordered: Number(r.ordered_qty), before: 0, now: 0
    }))
  };

  setText('slipOrderNo', `Advance Order #${h.transaction_no}`);
  setText('slipAoNo', h.receipt_no ? `Receipt No : ${h.receipt_no}` : '');
  setText('slipOrderDate', h.order_date ? `Order date: ${formatDate(h.order_date)}` : '');
  setText('slipLocation', h.warehouse_name ? `Location : ${h.warehouse_name}` : '');
  document.getElementById('slipReceiverName').innerHTML = `Receiver: <strong>${escapeHtml(h.customer_name)}</strong>`;
  setText('slipReceiverAddress', h.customer_address);
  setText('slipReceiverPhone', h.customer_mobile);
  setText('slipBatchNote', h.order_description ? `Order: ${h.order_description}` : '');
  document.getElementById('slipBatchNote').classList.toggle('hidden', !h.order_description);
  showBalance(h.net_amount, h.balance, h.fully_paid);

  enterManualMode(`pdslip:advance:${no}`);
  finishLoad(h.transaction_no);
}

function finishLoad(label) {
  document.getElementById('loadError').classList.add('hidden');
  document.getElementById('printBtn').disabled = false;
  render();
  document.title = `Delivery Slip ${label}`;
  document.getElementById('receiptContent').classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;

  const params = new URLSearchParams(window.location.search);
  const orderId = params.get('order');
  const advanceNo = params.get('advance');
  const batch = Number(params.get('batch')) || null;
  renderTopNav('Online Orders');
  if (!orderId && !advanceNo) return showError('Missing ?order= or ?advance= parameter.');

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    setText('unlockError', 'Please log out and log back in to view the slip.');
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('printBtn').addEventListener('click', () => window.print());
  document.getElementById('batchPick').addEventListener('change', (e) => {
    const n = Number(e.target.value);
    const url = new URL(window.location.href);
    url.searchParams.set('batch', n);
    history.replaceState(null, '', url);
    loadOnlineSlip(orderId, n);
  });
  wireEditor();

  renderCompanyHeader(await fetchCompanyInfo());
  if (advanceNo) await loadAdvanceSlip(advanceNo);
  else await loadOnlineSlip(orderId, batch);
})();
