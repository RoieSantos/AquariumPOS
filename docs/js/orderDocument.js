// Shared Order Confirmation / Invoice sheet (css/orderDocument.css) - one renderer so the three order
// documents stay identical: online-order-receipt.html (Order Confirmation), online-order-invoice.html
// (public Invoice) and gma-order-invoice.html (staff print Invoice). All three feed it the rows of
// public_get_order_receipt (sql/supabase_order_receipt_letterhead.sql) plus CompanyInfo from
// fetchCompanyInfo (js/companyBranding.js, General Setup); the branch contact comes from Warehouse Setup.
// Only the title and the notice text differ per document.

const ORDER_DOC_NOTICE_POLICY = `
  <p><span class="od-warn-title">IMPORTANT NOTICE:</span><br>
    All items must be claimed within <strong>30 days from the date of order confirmation</strong>. Beyond this period, unclaimed items will automatically incur a <strong>&#8369;250 per day storage fee</strong> until pickup. If the item remains unclaimed for <strong>40 days or more</strong>, RSPetStop reserves the right to <strong>terminate the order without refund</strong> and reallocate the item for resale.</p>`;

const ORDER_DOC_TYPES = {
  confirmation: {
    title: 'ORDER CONFIRMATION',
    pageTitle: 'Order Confirmation',
    notice: `
      <p>Please take note that once the order is <strong>confirmed</strong>, this quotation will serve as the <strong>final basis</strong> for the products you will receive.</p>
      <p>Any changes of this order will charge <strong>&#8369;150</strong>.</p>
      ${ORDER_DOC_NOTICE_POLICY}
      <p>Kindly review the details carefully and confirm if everything is in order.<br>
        We sincerely thank you for your trust and support. Happy Fish Keeping!</p>`
  },
  invoice: {
    title: 'INVOICE',
    pageTitle: 'Invoice',
    notice: `
      <p>Thank you for choosing <strong>RSPETSTOP</strong>. Please settle your balance according to the payment terms agreed with our staff.</p>
      ${ORDER_DOC_NOTICE_POLICY}
      <p>We appreciate your trust in us! Happy Fish Keeping!</p>`
  }
};

function odEsc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function odPeso(value) {
  return '&#8369; ' + Number(value || 0).toLocaleString('en-PH', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

function odDate(dateStr) {
  if (!dateStr) return '';
  const d = new Date(`${dateStr}T00:00:00`);
  if (Number.isNaN(d.getTime())) return dateStr;
  return d.toLocaleDateString('en-US', { month: '2-digit', day: '2-digit', year: 'numeric' });
}

function odKv(label, value) {
  return value ? `<div class="od-kv"><b>${odEsc(label)}:</b> ${odEsc(value)}</div>` : '';
}

function odLetterheadHtml(info) {
  const lines = [];
  if (info?.FacebookUrl) lines.push(`<div class="od-company-line"><a href="${odEsc(info.FacebookUrl)}" target="_blank" rel="noopener">${odEsc(info.FacebookUrl)}</a></div>`);
  if (info?.Address) lines.push(`<div class="od-company-line">Address: ${odEsc(info.Address)}</div>`);
  if (info?.ContactNo) lines.push(`<div class="od-company-line">Contact No: ${odEsc(info.ContactNo)}</div>`);
  if (info?.DtiNo) lines.push(`<div class="od-company-line">DTI No.: ${odEsc(info.DtiNo)}</div>`);
  return `
    <div class="od-company">
      ${info?.LogoUrl ? `<img class="od-logo" src="${odEsc(info.LogoUrl)}" alt="Logo">` : ''}
      <div>
        <div class="od-company-name">${odEsc(info?.CompanyName || 'RS Pet Stop')}</div>
        ${lines.join('')}
      </div>
    </div>`;
}

// rows = public_get_order_receipt result; info = CompanyInfo (may be null); type = 'confirmation' | 'invoice'.
function renderOrderDocument(container, rows, info, type) {
  const doc = ORDER_DOC_TYPES[type] || ORDER_DOC_TYPES.confirmation;
  const h = rows[0];
  const status = h.status_label || '';
  const chipClass = /pending/i.test(status) ? ' od-pending' : /cancel/i.test(status) ? ' od-cancelled' : '';
  const altNo = h.pancake_order_id && h.pancake_order_id !== h.order_id ? `(Online #${h.pancake_order_id})` : '';

  const lines = rows.filter((r) => r.line_no !== null);
  const linesHtml = lines.length === 0
    ? '<tr><td colspan="5" style="color:#5b6b80;">No items on this order.</td></tr>'
    : lines.map((r, i) => `
        <tr>
          <td class="od-idx">${i + 1}</td>
          <td>
            ${r.line_code ? `<span class="od-line-code">${odEsc(r.line_code)}</span>` : ''}
            <span class="od-line-name">${odEsc(r.line_description || '')}</span>
            ${r.line_note ? `<span class="od-line-note-inline">${odEsc(r.line_note)}</span>` : ''}
          </td>
          <td class="od-qty">${odEsc(r.line_quantity ?? '')}</td>
          <td class="od-note-col od-line-note">${odEsc(r.line_note || '')}</td>
          <td class="od-num">${odPeso(r.line_amount)}</td>
        </tr>`).join('');

  const gross = lines.reduce((sum, r) => sum + Number(r.line_amount || 0), 0);
  const discount = Math.abs(Number(h.discount || 0));
  const deliveryFee = Number(h.delivery_fee || 0);
  const net = Number(h.money_to_collect ?? (gross - discount + deliveryFee));
  const paid = Number(h.amount_paid || 0);
  const balance = Number(h.balance ?? (net - paid));

  container.innerHTML = `
    <div class="od-sheet">
      <div class="od-row">
        <div class="od-cell">${odLetterheadHtml(info)}</div>
        <div class="od-cell">
          <div class="od-order-no">Order #${odEsc(h.order_id || '')} <span class="od-alt">${odEsc(altNo)}</span></div>
          ${odKv('Sales Staff', h.sales_staff)}
          ${odKv('Creation date', odDate(h.order_date))}
          ${odKv('Location', h.warehouse_name)}
          ${odKv('Contact No.', h.warehouse_contact)}
          ${odKv('Address', h.warehouse_address)}
          ${status ? `<span class="od-chip${chipClass}">${odEsc(status)}</span>` : ''}
        </div>
      </div>

      <div class="od-row od-single">
        <div class="od-cell">
          <div>Receiver: <span class="od-receiver-name">${odEsc(h.customer_name || '')}</span></div>
          <div class="od-receiver-line">${odEsc(h.customer_phone || '-')}</div>
          <div class="od-receiver-line">${odEsc(h.shipping_address || 'Pickup')}</div>
        </div>
      </div>

      <div class="od-row od-single">
        <div style="min-width:0;">
          <div class="od-title">${doc.title}</div>
          <table class="od-lines">
            <thead>
              <tr><th class="od-idx">#</th><th>Products</th><th class="od-qty">Qty</th><th class="od-note-col">Note</th><th class="od-num">Amount</th></tr>
            </thead>
            <tbody>${linesHtml}</tbody>
          </table>
          <div class="od-extra">
            <div><b>Promotion:</b> </div>
            <div><b>Additional Note:</b> ${odEsc(h.note_print || '')}</div>
          </div>
        </div>
      </div>

      <div class="od-row">
        <div class="od-cell od-notice">${doc.notice}</div>
        <div class="od-cell od-totals">
          <div class="od-t-row"><span>Gross Amount</span><span>${odPeso(gross)}</span></div>
          <div class="od-t-row"><span>Discount</span><span>${odPeso(discount)}</span></div>
          <div class="od-t-row"><span>Delivery Fee</span><span>${odPeso(deliveryFee)}</span></div>
          <div class="od-t-row od-net"><span>Net Total</span><span>${odPeso(net)}</span></div>
          <div class="od-t-row"><span>Amount Paid</span><span>${odPeso(paid)}</span></div>
          <div class="od-t-row od-balance${balance <= 0 ? ' od-paid' : ''}"><span>Balance</span><span class="od-v">${odPeso(balance)}</span></div>
        </div>
      </div>
    </div>`;

  return `${doc.pageTitle} #${h.order_id || ''} - RS Pet Stop`;
}
