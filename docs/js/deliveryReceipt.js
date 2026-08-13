// Per-order printable Delivery Receipt (?stop=<DeliveryStops.StopID>), linked from the "Print"
// button on each row of the Delivery day-detail Stops table (js/delivery.js). Mirrors the
// Pancake-generated delivery receipt layout the shop already prints from Pancake itself - see
// admin_get_delivery_receipt (supabase_delivery_receipt.sql) for the header + line data, and
// fetchCompanyInfo (js/companyBranding.js) for the letterhead fields. Same trust tier as
// Delivery itself (any active staff, reuses session.password, no re-unlock prompt beyond the
// stale-session fallback).
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

function renderReceiptLines(rows) {
  const tbody = document.getElementById('receiptLinesBody');
  const realLines = rows.filter((r) => r.line_no !== null);

  tbody.innerHTML = realLines.length === 0
    ? '<tr><td colspan="2" class="muted">No line items on this order.</td></tr>'
    : realLines
        .map((r) => `
          <tr>
            <td>${r.line_description || ''}</td>
            <td>${r.line_quantity != null ? r.line_quantity : ''}</td>
          </tr>
        `)
        .join('');
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

  document.getElementById('receiptOrderNo').textContent = `Order #${header.order_id || ''}`;
  document.getElementById('receiptCreationDate').textContent = `Creation date: ${formatReceiptDate(header.order_date)}`;

  document.getElementById('receiptReceiverName').innerHTML = `Receiver: <strong>${header.customer_name || ''}</strong>`;
  document.getElementById('receiptReceiverAddress').textContent = header.shipping_address || '';
  document.getElementById('receiptReceiverPhone').textContent = header.shipping_phone || '';

  renderReceiptLines(data);

  document.getElementById('receiptNote').textContent = `Additional NOTE: ${header.note_print || ''}`;
  document.getElementById('receiptDeliveryFee').textContent = `Delivery Fee : ${formatMoney(header.delivery_fee)}`;
  document.getElementById('receiptCustomerLine').textContent = `Customer : ${header.customer_name || ''}`;

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
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view the Delivery Receipt.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('printBtn').addEventListener('click', () => window.print());

  const info = await fetchCompanyInfo();
  renderCompanyHeader(info);

  await loadReceipt(stopId);
})();
