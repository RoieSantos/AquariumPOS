// Printable single Purchase Order (?po=PO-0001), linked from Purchase Orders' list page
// (js/purchaseOrders.js) and directly after creating one from Stock On Hand (js/stockOnHand.js).
let currentSession = null;

function formatDate(value) {
  if (!value) return '';
  const d = new Date(value);
  return isNaN(d.getTime()) ? value : d.toLocaleDateString();
}

function renderLines(lines) {
  const body = document.getElementById('poLinesBody');
  if (!lines || lines.length === 0) {
    body.innerHTML = '<tr><td colspan="4" class="muted">No line items.</td></tr>';
    return;
  }

  body.innerHTML = lines
    .map((l) => `
      <tr>
        <td>${l.item_code || ''}</td>
        <td>${l.item_name || ''}</td>
        <td>${l.warehouse_name || ''}</td>
        <td style="text-align:right;">${Number(l.quantity || 0).toLocaleString()}</td>
      </tr>
    `)
    .join('');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Purchase Orders');
  await renderCompanyLetterhead('companyLetterhead');

  document.getElementById('printBtn').addEventListener('click', () => window.print());

  const poNo = new URLSearchParams(window.location.search).get('po');
  if (!poNo) {
    document.getElementById('poSubtitle').textContent = 'Missing ?po= parameter.';
    document.getElementById('poContent').classList.remove('hidden');
    return;
  }

  const [{ data: headerRows, error: headerError }, { data: lineRows, error: lineError }] = await Promise.all([
    supabaseClient.rpc('staff_get_purchase_order', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_po_no: poNo
    }),
    supabaseClient.rpc('staff_list_purchase_order_lines', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_po_no: poNo
    })
  ]);

  if (headerError || !headerRows || headerRows.length === 0) {
    document.getElementById('poSubtitle').textContent = headerError?.message || `Purchase Order ${poNo} not found.`;
    document.getElementById('poContent').classList.remove('hidden');
    return;
  }

  const header = headerRows[0];
  document.getElementById('poNo').textContent = header.po_no || '';
  document.getElementById('poVendor').textContent = header.vendor_name || header.vendor_code || '';
  document.getElementById('poDate').textContent = formatDate(header.order_date);
  document.getElementById('poNotes').textContent = header.notes || '-';
  document.getElementById('poSubtitle').textContent = `Created by ${header.created_by || 'unknown'} on ${formatDate(header.created_at_utc)}`;

  if (lineError) {
    document.getElementById('poLinesBody').innerHTML = `<tr><td class="error-text">${lineError.message}</td></tr>`;
  } else {
    renderLines(lineRows || []);
  }

  document.getElementById('poContent').classList.remove('hidden');
})();
