// Per-order printable Invoice for an AutomatedOrders order (?order=<AutomatedOrders.OrderNo>),
// linked from a "Invoice" button on each order card in GMA Conversations (docs/js/gmaConversations.js).
// A staff-only companion to docs/online-order-receipt.html's "Order Confirmation" (public, no-login,
// already fully supports AO-xxxxx orders via public_get_order_receipt) - this one instead carries
// staff-only detail (Sales Staff, phone number, branch address) that a customer-facing link
// shouldn't. Reuses invoice.js's own structure/CSS classes verbatim (.delivery-receipt-*/.invoice-*,
// see css/styles.css) - same look and feel as every other printed document in this portal, just
// backed by admin_get_automated_order_invoice (supabase_gma_conversation_order_invoice.sql) instead
// of admin_get_delivery_receipt.
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

async function loadInvoice(orderNo) {
  const errorEl = document.getElementById('loadError');

  const { data, error } = await supabaseClient.rpc('admin_get_automated_order_invoice', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_no: orderNo
  });

  if (error || !data || data.length === 0) {
    errorEl.textContent = (error && error.message) || `No order found matching "${orderNo}".`;
    errorEl.classList.remove('hidden');
    return;
  }

  const header = data[0];

  document.getElementById('receiptOrderNo').textContent = `Order #${header.order_no || ''}`;
  document.getElementById('receiptSalesStaff').textContent = `Sales Staff : ${header.sales_staff || ''}`;
  document.getElementById('receiptCreationDate').textContent = `Creation date: ${formatReceiptDate(header.order_date)}`;
  document.getElementById('receiptLocation').textContent = `Location : ${header.location || ''}`;
  document.getElementById('receiptWarehouseAddress').textContent = header.warehouse_address ? `Address : ${header.warehouse_address}` : '';

  document.getElementById('receiptReceiverName').innerHTML = `Receiver: <strong>${header.customer_name || ''}</strong>`;
  document.getElementById('receiptReceiverAddress').textContent = header.shipping_address || 'Pickup';
  document.getElementById('receiptReceiverPhone').textContent = header.customer_phone || '';

  renderInvoiceLines(data);

  const noteEl = document.getElementById('receiptNote');
  if (header.note_print) {
    noteEl.textContent = `Additional NOTE: ${header.note_print}`;
    noteEl.classList.remove('hidden');
  } else {
    noteEl.classList.add('hidden');
  }

  document.getElementById('summaryTotal').textContent = formatMoney(header.total);
  document.getElementById('summaryAmountPaid').textContent = formatMoney(header.amount_paid);
  document.getElementById('summaryBalance').textContent = formatMoney(header.balance);

  document.getElementById('receiptContent').classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('GMA Conversations');

  const orderNo = new URLSearchParams(window.location.search).get('order');
  if (!orderNo) {
    document.getElementById('loadError').textContent = 'Missing ?order= parameter.';
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

  await loadInvoice(orderNo);
})();
