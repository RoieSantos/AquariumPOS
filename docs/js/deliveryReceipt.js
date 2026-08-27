// Per-stop printable bundle (?stop=<DeliveryStops.StopID>), linked from the "Print" button on
// each row of the Delivery day-detail Stops table (js/delivery.js). Mirrors the Pancake-generated
// delivery receipt layout the shop already prints from Pancake itself - see
// admin_get_delivery_receipt (supabase_delivery_receipt.sql) for the header + line data, and
// fetchCompanyInfo (js/companyBranding.js) for the letterhead fields. Same trust tier as Delivery
// itself (any active staff, reuses session.password, no re-unlock prompt beyond the stale-session
// fallback).
//
// Per direct request, one click here produces ONE print job containing 2 Delivery Receipt copies
// always, plus 1 Invoice copy appended whenever the order still has a Balance owing (skipped
// entirely for a fully-paid order) - so staff don't need a separate manual "Print Invoice" trip
// for the common case, but a settled order still just prints its plain 2-copy receipt. There's no
// web API to preset the OS print dialog's own "copies" field, so this builds each occurrence as
// its own HTML block (deliveryReceiptBlockHtml / invoiceBlockHtml below) and stacks them into
// #printArea, each wrapped in .print-page (page-break-after: always in @media print, see
// css/styles.css) - one window.print() call then produces the whole correctly-paginated job.
//
// The standalone docs/invoice.html/js/invoice.js ("Print Invoice" button) is untouched by this -
// it stays available for reprinting just the invoice on its own later (e.g. after the balance is
// eventually settled).
let currentSession = null;
let companyInfo = null;

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

function escapeHtml(value) {
  return (value ?? '').toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Shared letterhead fragment (logo + company name/FB/address/contact/DTI/TIN) - used inside both
// the Delivery Receipt's single-column header and the Invoice's two-column header.
function companyInfoHtml(info) {
  info = info || {};
  const logo = info['LogoUrl']
    ? `<img class="delivery-receipt-logo" src="${escapeHtml(info['LogoUrl'])}" alt="Company logo" />`
    : '';
  return `
    ${logo}
    <div class="delivery-receipt-company-info">
      <div class="delivery-receipt-company-name">${escapeHtml(info['CompanyName'])}</div>
      <div class="delivery-receipt-line">${escapeHtml(info['FacebookUrl'])}</div>
      ${info['Address'] ? `<div class="delivery-receipt-line">Address : ${escapeHtml(info['Address'])}</div>` : ''}
      ${info['ContactNo'] ? `<div class="delivery-receipt-line">Contact No : ${escapeHtml(info['ContactNo'])}</div>` : ''}
      ${info['DtiNo'] ? `<div class="delivery-receipt-line">DTI No.: ${escapeHtml(info['DtiNo'])}</div>` : ''}
      ${info['TinNo'] ? `<div class="delivery-receipt-line">TIN No.: ${escapeHtml(info['TinNo'])}</div>` : ''}
    </div>
  `;
}

// A line's own Note (e.g. a custom aquarium's dimensions/sealant spec) prints as its own
// full-width row directly under that line, so it stays attached to the product it describes
// instead of being merged into the single header-level "Additional NOTE" blob further down.
function lineNoteRowHtml(r, colspan) {
  return r.line_note
    ? `<tr><td colspan="${colspan}" class="delivery-receipt-line-note">Note: ${escapeHtml(r.line_note)}</td></tr>`
    : '';
}

function receiptLinesRowsHtml(lines) {
  const realLines = lines.filter((r) => r.line_no !== null);
  return realLines.length === 0
    ? '<tr><td colspan="2" class="muted">No line items on this order.</td></tr>'
    : realLines
        .map((r) => `
          <tr>
            <td>${escapeHtml(r.line_description)}</td>
            <td>${r.line_quantity != null ? escapeHtml(r.line_quantity) : ''}</td>
          </tr>
          ${lineNoteRowHtml(r, 2)}
        `)
        .join('');
}

function invoiceLinesRowsHtml(lines) {
  const realLines = lines.filter((r) => r.line_no !== null);
  return realLines.length === 0
    ? '<tr><td colspan="4" class="muted">No line items on this order.</td></tr>'
    : realLines
        .map((r) => `
          <tr>
            <td>${r.line_no}</td>
            <td>${escapeHtml(r.line_description)}</td>
            <td>${r.line_quantity != null ? escapeHtml(r.line_quantity) : ''}</td>
            <td style="text-align:right;">${formatMoney(r.line_amount)}</td>
          </tr>
          ${lineNoteRowHtml(r, 4)}
        `)
        .join('');
}

// One Delivery Receipt copy (signature/terms-focused, no pricing) - matches the layout previously
// hardcoded in docs/delivery-receipt.html, now built per-copy so it can be repeated.
function deliveryReceiptBlockHtml(info, header, lines, copyLabel) {
  return `
    <div class="print-page">
      <div class="no-print print-page-label">${escapeHtml(copyLabel)}</div>
      <div class="delivery-receipt">
        <div class="delivery-receipt-section delivery-receipt-header">
          ${companyInfoHtml(info)}
        </div>
        <div class="delivery-receipt-section">
          <div class="delivery-receipt-line">Order #${escapeHtml(header.order_id)}</div>
          <div class="delivery-receipt-line">Creation date: ${formatReceiptDate(header.order_date)}</div>
        </div>
        <div class="delivery-receipt-section">
          <div class="delivery-receipt-line">Receiver: <strong>${escapeHtml(header.customer_name)}</strong></div>
          <div class="delivery-receipt-line">${escapeHtml(header.shipping_address)}</div>
          <div class="delivery-receipt-line">${escapeHtml(header.shipping_phone)}</div>
        </div>
        <div class="delivery-receipt-section">
          <div class="delivery-receipt-title">DELIVERY RECEIPT</div>
        </div>
        <div class="delivery-receipt-section">
          <div class="table-wrap">
            <table>
              <thead>
                <tr><th>Products</th><th>Qty</th></tr>
              </thead>
              <tbody>${receiptLinesRowsHtml(lines)}</tbody>
            </table>
          </div>
          ${header.note_print ? `<div class="delivery-receipt-note">Additional NOTE: ${escapeHtml(header.note_print)}</div>` : ''}
          <div class="delivery-receipt-fee">Delivery Fee : ${formatMoney(header.delivery_fee)}</div>
        </div>
        <div class="delivery-receipt-section">
          <ul class="delivery-receipt-terms">
            <li>Our team completes Delivery / Installation strictly according to the client's approved specifications. By signing, the client confirms that all items have been inspected, tested, and accepted in proper working condition, and expresses satisfaction with the setup upon turnover.</li>
            <li>Our team guarantees leak coverage for 10 days, subject to no external force or impact. Any valid concerns will be resolved swiftly and professionally.</li>
            <li>The receiving party has received and agreed to sign this form.</li>
            <li>The form are prepared in two copies, each party keeps one copy, and they have equal legal validity.</li>
          </ul>
        </div>
        <div class="delivery-receipt-section delivery-receipt-signature-row">
          <div class="delivery-receipt-signature-left">
            <div>Delivery Date ________________________</div>
            <div>Delivery By :</div>
          </div>
          <div class="delivery-receipt-signature-right">Customer : ${escapeHtml(header.customer_name)}</div>
        </div>
      </div>
    </div>
  `;
}

// One Invoice copy (itemized: Sales Staff, branch/Location, per-line Amount, Total/Discount/
// Amount Paid/Balance summary) - matches the layout previously hardcoded in docs/invoice.html.
function invoiceBlockHtml(info, header, lines) {
  return `
    <div class="print-page">
      <div class="no-print print-page-label">Invoice (balance due)</div>
      <div class="delivery-receipt">
        <div class="delivery-receipt-section invoice-header">
          <div class="delivery-receipt-header">
            ${companyInfoHtml(info)}
          </div>
          <div class="invoice-order-info">
            <div class="delivery-receipt-line">Order #${escapeHtml(header.order_id)}</div>
            <div class="delivery-receipt-line">Sales Staff : ${escapeHtml(header.confirmed_by)}</div>
            <div class="delivery-receipt-line">Creation date: ${formatReceiptDate(header.order_date)}</div>
            <div class="delivery-receipt-line">Location : ${escapeHtml(header.warehouse_name)}</div>
            ${header.warehouse_address ? `<div class="delivery-receipt-line">Address : ${escapeHtml(header.warehouse_address)}</div>` : ''}
          </div>
        </div>
        <div class="delivery-receipt-section">
          <div class="delivery-receipt-line">Receiver: <strong>${escapeHtml(header.customer_name)}</strong></div>
          <div class="delivery-receipt-line">${escapeHtml(header.shipping_address)}</div>
          <div class="delivery-receipt-line">${escapeHtml(header.shipping_phone)}</div>
        </div>
        <div class="delivery-receipt-section">
          <div class="delivery-receipt-title">INVOICE</div>
        </div>
        <div class="delivery-receipt-section">
          <div class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>#</th>
                  <th>Products</th>
                  <th>Qty</th>
                  <th style="text-align:right;">Amount</th>
                </tr>
              </thead>
              <tbody>${invoiceLinesRowsHtml(lines)}</tbody>
            </table>
          </div>
          ${header.note_print ? `<div class="delivery-receipt-note">Additional NOTE: ${escapeHtml(header.note_print)}</div>` : ''}
          <div class="delivery-receipt-fee">Delivery Fee : ${formatMoney(header.delivery_fee)}</div>
        </div>
        <div class="delivery-receipt-section">
          <p>Thank you for choosing RSPETSTOP. Please settle your balance according to the payment terms stated above. Delivery fees are customer-shouldered unless arranged in advance.</p>
          <p>We appreciate your trust in us! Happy Fish Keeping!</p>
        </div>
        <div class="delivery-receipt-section">
          <div class="invoice-summary">
            <div class="invoice-summary-row"><span>Total</span><span>${formatMoney(header.money_to_collect)}</span></div>
            <div class="invoice-summary-row"><span>Discount</span><span>${formatMoney(header.discount)}</span></div>
            <div class="invoice-summary-row"><span>Amount Paid</span><span>${formatMoney(header.amount_paid)}</span></div>
            <div class="invoice-summary-row invoice-summary-balance"><span>Balance</span><span>${formatMoney(header.balance)}</span></div>
          </div>
        </div>
      </div>
    </div>
  `;
}

async function loadReceipt(stopId) {
  const errorEl = document.getElementById('loadError');

  const { data, error } = await supabaseClient.rpc('admin_get_delivery_receipt', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_stop_id: stopId
  });

  if (error || !data || data.length === 0) {
    errorEl.textContent = (error && error.message) || 'Could not load this delivery receipt.';
    errorEl.classList.remove('hidden');
    return;
  }

  const header = data[0];
  const balance = Number(header.balance) || 0;

  const printArea = document.getElementById('printArea');
  printArea.innerHTML =
    deliveryReceiptBlockHtml(companyInfo, header, data, 'Delivery Receipt - Copy 1 of 2') +
    deliveryReceiptBlockHtml(companyInfo, header, data, 'Delivery Receipt - Copy 2 of 2') +
    (balance > 0 ? invoiceBlockHtml(companyInfo, header, data) : '');

  // On-screen only, so staff know what this Print click is about to produce before they commit
  // paper to it - not shown in the print output itself.
  document.getElementById('printSummaryNote').textContent = balance > 0
    ? 'This will print 2 Delivery Receipt copies, plus 1 Invoice copy (balance due).'
    : 'This will print 2 Delivery Receipt copies.';

  printArea.classList.remove('hidden');
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
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view the Delivery Receipt.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('printBtn').addEventListener('click', () => window.print());

  companyInfo = await fetchCompanyInfo();

  await loadReceipt(stopId);
})();
