// Per-order printable Invoice (?stop=<DeliveryStops.StopID>), linked from the "Print Invoice"
// button on each row of the Delivery day-detail Stops table (js/delivery.js) - an itemized
// alternative to the plain Delivery Receipt (docs/delivery-receipt.html/js/deliveryReceipt.js),
// for the same stop: Sales Staff, branch/Location, per-line Amount, and a Total/Discount/Amount
// Paid/Balance summary. Reuses the same admin_get_delivery_receipt RPC (supabase_delivery_
// receipt.sql) - it already returns everything this page needs alongside what the Delivery
// Receipt uses. Same trust tier as Delivery Receipt (any active staff, reuses session.password,
// no re-unlock prompt beyond the stale-session fallback).
let currentSession = null;

function formatMoney(value) {
  return `₱ ${Number(value || 0).toFixed(2)}`;
}

function formatReceiptDate(dateStr) {
  if (!dateStr) return '';
  const d = new Date(`${dateStr}T00:00:00`);
  if (Number.isNaN(d.getTime())) return dateStr;
  const dd = String(d.getDate()).padStart(2, '0');
  const mm = String(d.getMonth() + 1).padStart(2, '0');
  return `${dd}/${mm}/${d.getFullYear()}`;
}

function renderCompanyHeader(info) {
  if (!info) return;

  const logo = document.getElementById('receiptLogo');
  if (info['LogoUrl']) {
    logo.src = info['LogoUrl'];
    logo.classList.remove('hidden');
  }

  document.getElementById('receiptCompanyName').textContent = info['CompanyName'] || '';
  document.getElementById('receiptFacebook').textContent = info['FacebookUrl'] || '';
  document.getElementById('receiptAddress').textContent = info['Address'] ? `Address : ${info['Address']}` : '';
  document.getElementById('receiptContactNo').textContent = info['ContactNo'] ? `Contact No : ${info['ContactNo']}` : '';
  document.getElementById('receiptDtiNo').textContent = info['DtiNo'] ? `DTI No.: ${info['DtiNo']}` : '';
  document.getElementById('receiptTinNo').textContent = info['TinNo'] ? `TIN No.: ${info['TinNo']}` : '';
}

// A line's own Note (e.g. a custom aquarium's dimensions/sealant spec) prints as its own
// full-width row directly under that line, so it stays attached to the product it describes
// instead of being merged into the single header-level "Additional NOTE" line further down.
function lineNoteRowHtml(r) {
  return r.line_note
    ? `<tr><td colspan="4" class="delivery-receipt-line-note">Note: ${r.line_note}</td></tr>`
    : '';
}

function renderInvoiceLines(rows) {
  const tbody = document.getElementById('receiptLinesBody');
  const realLines = rows.filter((r) => r.line_no !== null);

  tbody.innerHTML = realLines.length === 0
    ? '<tr><td colspan="4" class="muted">No line items on this order.</td></tr>'
    : realLines
        .map((r) => `
          <tr>
            <td>${r.line_no}</td>
            <td>${r.line_description || ''}</td>
            <td>${r.line_quantity != null ? r.line_quantity : ''}</td>
            <td style="text-align:right;">${formatMoney(r.line_amount)}</td>
          </tr>
          ${lineNoteRowHtml(r)}
        `)
        .join('');
}

async function loadInvoice(stopId) {
  const errorEl = document.getElementById('loadError');

  const { data, error } = await supabaseClient.rpc('admin_get_delivery_receipt', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_stop_id: stopId
  });

  if (error || !data || data.length === 0) {
    errorEl.textContent = (error && error.message) || 'Could not load this invoice.';
    errorEl.classList.remove('hidden');
    return;
  }

  const header = data[0];

  document.getElementById('receiptOrderNo').textContent = `Order #${header.order_id || ''}`;
  document.getElementById('receiptSalesStaff').textContent = `Sales Staff : ${header.confirmed_by || ''}`;
  document.getElementById('receiptCreationDate').textContent = `Creation date: ${formatReceiptDate(header.order_date)}`;
  document.getElementById('receiptLocation').textContent = `Location : ${header.warehouse_name || ''}`;
  document.getElementById('receiptWarehouseAddress').textContent = header.warehouse_address ? `Address : ${header.warehouse_address}` : '';

  document.getElementById('receiptReceiverName').innerHTML = `Receiver: <strong>${header.customer_name || ''}</strong>`;
  document.getElementById('receiptReceiverAddress').textContent = header.shipping_address || '';
  document.getElementById('receiptReceiverPhone').textContent = header.shipping_phone || '';

  renderInvoiceLines(data);

  const noteEl = document.getElementById('receiptNote');
  if (header.note_print) {
    noteEl.textContent = `Additional NOTE: ${header.note_print}`;
    noteEl.classList.remove('hidden');
  } else {
    noteEl.classList.add('hidden');
  }
  document.getElementById('receiptDeliveryFee').textContent = `Delivery Fee : ${formatMoney(header.delivery_fee)}`;

  document.getElementById('summaryTotal').textContent = formatMoney(header.money_to_collect);
  document.getElementById('summaryDiscount').textContent = formatMoney(header.discount);
  document.getElementById('summaryAmountPaid').textContent = formatMoney(header.amount_paid);
  document.getElementById('summaryBalance').textContent = formatMoney(header.balance);

  document.getElementById('receiptContent').classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Delivery');

  const stopId = new URLSearchParams(window.location.search).get('stop');
  if (!stopId) {
    document.getElementById('loadError').textContent = 'Missing ?stop= parameter.';
    document.getElementById('loadError').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view the Invoice.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('printBtn').addEventListener('click', () => window.print());

  const info = await fetchCompanyInfo();
  renderCompanyHeader(info);

  await loadInvoice(stopId);
})();
