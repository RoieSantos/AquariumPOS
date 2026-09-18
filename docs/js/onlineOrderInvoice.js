// Public, no-login "Invoice" view of an order (?order=<AutomatedOrders.OrderNo or an Online Order
// id>) - the formal counterpart to docs/online-order-receipt.html's simpler "Order Confirmation",
// per direct request to let staff choose which one to send a customer from GMA Conversations (see
// sendReceiptToCustomer in docs/js/gmaConversations.js). Reuses the SAME public_get_order_receipt
// RPC as online-order-receipt.html (already tries Automated Orders first, then Online Orders - see
// supabase_automated_order_portal_receipt.sql) and the same .delivery-receipt-*/.invoice-* layout
// as the staff-only docs/gma-order-invoice.html/js/gmaOrderInvoice.js - just without that page's
// Sales Staff/phone fields, since this link is safe to hand straight to a customer.
function formatMoney(value) {
  return `₱ ${Number(value || 0).toFixed(2)}`;
}

function formatDate(dateStr) {
  if (!dateStr) return '';
  const d = new Date(`${dateStr}T00:00:00`);
  if (Number.isNaN(d.getTime())) return dateStr;
  return d.toLocaleDateString('en-PH', { year: 'numeric', month: 'short', day: 'numeric' });
}

async function renderCompanyHeader() {
  const info = await fetchCompanyInfo();
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
}

function lineNoteRowHtml(r) {
  return r.line_note
    ? `<tr><td colspan="4" class="delivery-receipt-line-note">Note: ${r.line_note}</td></tr>`
    : '';
}

function renderInvoice(rows) {
  const header = rows[0];
  document.getElementById('statusMessage').classList.add('hidden');
  document.getElementById('receiptContent').classList.remove('hidden');

  document.getElementById('receiptOrderNo').textContent = `Order #${header.order_id || ''}`;
  document.getElementById('receiptCreationDate').textContent = `Order date: ${formatDate(header.order_date)}`;
  document.getElementById('receiptLocation').textContent = header.warehouse_name ? `Branch : ${header.warehouse_name}` : '';

  document.getElementById('receiptReceiverName').innerHTML = `Receiver: <strong>${header.customer_name || ''}</strong>`;
  document.getElementById('receiptReceiverAddress').textContent = header.shipping_address || 'Pickup';

  const realLines = rows.filter((r) => r.line_no !== null);
  const linesBody = document.getElementById('receiptLinesBody');
  linesBody.innerHTML = realLines.length === 0
    ? '<tr><td colspan="4" class="muted">No line items on this order.</td></tr>'
    : realLines.map((r) => `
        <tr>
          <td>${r.line_no}</td>
          <td>${r.line_description || ''}</td>
          <td>${r.line_quantity != null ? r.line_quantity : ''}</td>
          <td style="text-align:right;">${formatMoney(r.line_amount)}</td>
        </tr>
        ${lineNoteRowHtml(r)}
      `).join('');

  const noteEl = document.getElementById('receiptNote');
  if (header.note_print) {
    noteEl.textContent = `Additional NOTE: ${header.note_print}`;
    noteEl.classList.remove('hidden');
  } else {
    noteEl.classList.add('hidden');
  }

  document.getElementById('summaryTotal').textContent = formatMoney(header.money_to_collect);
  document.getElementById('summaryAmountPaid').textContent = formatMoney(header.amount_paid);
  document.getElementById('summaryBalance').textContent = formatMoney(header.balance);
}

async function loadInvoice() {
  const orderId = new URLSearchParams(window.location.search).get('order');
  const statusEl = document.getElementById('statusMessage');
  if (!orderId) {
    statusEl.textContent = 'No order number given - open this page from the link shared with you.';
    return;
  }

  const { data, error } = await supabaseClient.rpc('public_get_order_receipt', { p_order_no: orderId });
  if (error) {
    statusEl.textContent = 'Could not load this invoice right now - please try again shortly.';
    return;
  }
  if (!data || data.length === 0) {
    statusEl.textContent = `No order found matching "${orderId}".`;
    return;
  }

  await renderCompanyHeader();
  renderInvoice(data);
}

loadInvoice();
