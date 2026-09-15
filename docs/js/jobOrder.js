// Per-stop Job Order printout (?stop=<DeliveryStops.StopID>), linked from the "Print Job Order"
// button on each row of the Delivery day-detail Stops table (js/delivery.js). Reuses the same
// admin_get_delivery_receipt RPC as the Delivery Receipt/Invoice (supabase_delivery_receipt.sql)
// for the header/receiver fields, and fetchCompanyInfo (js/companyBranding.js) for the letterhead
// - but unlike those two, a Job Order has no product/pricing lines, just a free-text Job
// Description the staff member typed at print time (there's nothing in Pancake/OnlineOrders for
// "job description" to pull from automatically). Same trust tier as Delivery itself.
let currentSession = null;
let companyInfo = null;
let orderHeader = null;

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

// Shared letterhead fragment - same markup/classes as Delivery Receipt and Invoice so the three
// print outs stay visually consistent (see .delivery-receipt-* in css/styles.css).
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

function jobOrderBlockHtml(info, header, jobDescription) {
  return `
    <div class="print-page">
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
          <div class="delivery-receipt-title">JOB ORDER</div>
        </div>
        <div class="delivery-receipt-section delivery-receipt-jobdesc">
          <div class="delivery-receipt-jobdesc-label">JOB DESCRIPTION:</div>
          <div class="delivery-receipt-jobdesc-body">${escapeHtml(jobDescription)}</div>
        </div>
        <div class="delivery-receipt-section">
          <ul class="delivery-receipt-terms">
            <li>Our team completes Delivery / Installation strictly according to the client's approved specifications. By signing, the client confirms that all items have been inspected, tested, and accepted in proper working condition, and expresses satisfaction with the setup upon turnover.</li>
            <li>The receiving party has received and agreed to sign this form.</li>
            <li>The form are prepared in two copies, each party keeps one copy, and they have equal legal validity.</li>
          </ul>
        </div>
        <div class="delivery-receipt-section delivery-receipt-signature-row">
          <div class="delivery-receipt-signature-left">
            <div>Date:</div>
            <div>Delivery By :</div>
          </div>
          <div class="delivery-receipt-signature-right">Customer : ${escapeHtml(header.customer_name)}</div>
        </div>
      </div>
    </div>
  `;
}

function renderJobOrder() {
  const jobDescription = document.getElementById('jobDescriptionInput').value;
  const printArea = document.getElementById('printArea');
  printArea.innerHTML = jobOrderBlockHtml(companyInfo, orderHeader, jobDescription);
  printArea.classList.remove('hidden');
}

async function loadJobOrder(stopId) {
  const errorEl = document.getElementById('loadError');

  const { data, error } = await supabaseClient.rpc('admin_get_delivery_receipt', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_stop_id: stopId
  });

  if (error || !data || data.length === 0) {
    errorEl.textContent = (error && error.message) || 'Could not load this order.';
    errorEl.classList.remove('hidden');
    return;
  }

  orderHeader = data[0];
  renderJobOrder();
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
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view the Job Order.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('printBtn').addEventListener('click', () => window.print());
  document.getElementById('jobDescriptionInput').addEventListener('input', renderJobOrder);

  companyInfo = await fetchCompanyInfo();

  await loadJobOrder(stopId);
})();
