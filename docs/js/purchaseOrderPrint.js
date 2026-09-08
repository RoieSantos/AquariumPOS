// Printable single Purchase Order (?po=PO-0001), linked from Purchase Orders' list page
// (js/purchaseOrders.js), Posted Purchase Orders (js/postedPurchaseOrders.js), and directly after
// creating one from Stock On Hand (js/stockOnHand.js). Tries the live PurchaseOrders table first,
// then falls back to PostedPurchaseOrders (see supabase_purchase_order_receiving.sql) - once a PO
// is posted it no longer exists in the live table, but this same URL (already handed out/printed
// before posting) should keep working.
let currentSession = null;

function formatDate(value) {
  if (!value) return '';
  const d = new Date(value);
  return isNaN(d.getTime()) ? value : d.toLocaleDateString();
}

// Description is unconstrained free text (js/purchaseOrders.js), unlike item_code/item_name which
// come from a catalog picker - escaped before going into innerHTML.
function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[ch]);
}

// The vendor is being asked for boxes, so a line ordered in one leads with "5 BOX" and carries the
// base quantity underneath - that second figure is what the delivery gets counted against on
// arrival. A line ordered in its base unit just prints the one number.
// See supabase_units_of_measure.sql.
// The price of one of whatever the Quantity column is counting (unit_cost_uom, derived by the
// list RPCs - see supabase_purchase_order_line_uom_edit.sql). A line ordered in boxes has to print
// the box price, or "5 BOX x 40.00 = 2,400.00" goes to the vendor as arithmetic that does not
// work. unit_cost itself stays per base unit everywhere it is stored.
function unitCostPerUomText(l) {
  const value = l.unit_cost_uom ?? l.unit_cost;
  return value === null || value === undefined ? '-' : Number(value).toFixed(2);
}

function quantityWithUomHtml(l) {
  const base = Number(l.quantity || 0).toLocaleString();
  if (!l.uom_code || !l.quantity_uom || Number(l.qty_per_uom || 1) === 1) return base;

  return `${Number(l.quantity_uom).toLocaleString()} ${escapeHtml(l.uom_code)}`
    + `<div class="muted" style="font-size:11px;">${base}</div>`;
}

function renderLines(lines) {
  const body = document.getElementById('poLinesBody');
  const totalEl = document.getElementById('poTotalCost');

  if (!lines || lines.length === 0) {
    body.innerHTML = '<tr><td colspan="6" class="muted">No line items.</td></tr>';
    if (totalEl) totalEl.textContent = '0.00';
    return;
  }

  // line_cost is computed server-side by the list RPCs (see
  // supabase_item_cost_and_po_line_cost.sql). This page prints BOTH open and posted POs, and the
  // two cost their lines differently on purpose - an open PO against Qty Ordered (nothing has
  // arrived yet), a posted one against Qty Received (what was actually paid for). Summing the
  // server's figure keeps this sheet agreeing with whichever it was handed.
  if (totalEl) {
    totalEl.textContent = lines
      .reduce((sum, l) => sum + (Number(l.line_cost) || 0), 0)
      .toFixed(2);
  }

  // An item's vendor code only exists for vendors who have given you one (the Vendors list in Item
  // Setup's factbox), so the column earns its place per order rather than printing blank.
  const showVendorItemNo = lines.some((l) => l.vendor_item_no);
  document.getElementById('poVendorItemNoHeader').classList.toggle('hidden', !showVendorItemNo);
  document.getElementById('poTotalCostLabel').colSpan = showVendorItemNo ? 6 : 5;

  body.innerHTML = lines
    .map((l) => `
      <tr>
        <td>${l.item_code || ''}</td>
        ${showVendorItemNo ? `<td>${escapeHtml(l.vendor_item_no || '')}</td>` : ''}
        <td>${l.item_name || ''}</td>
        <td>${escapeHtml(l.description || '')}</td>
        <td style="text-align:right;">${quantityWithUomHtml(l)}</td>
        <td style="text-align:right;">${unitCostPerUomText(l)}</td>
        <td style="text-align:right;">${l.unit_cost === null || l.unit_cost === undefined ? '-' : Number(l.line_cost || 0).toFixed(2)}</td>
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

  let [{ data: headerRows, error: headerError }, { data: lineRows, error: lineError }] = await Promise.all([
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

  // Not found live (or nothing came back) - it may have already been posted, so fall back to the
  // Posted Purchase Orders archive before giving up.
  if (!headerError && (!headerRows || headerRows.length === 0)) {
    const [postedHeader, postedLines] = await Promise.all([
      supabaseClient.rpc('staff_get_posted_purchase_order', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_po_no: poNo
      }),
      supabaseClient.rpc('staff_list_posted_purchase_order_lines', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_po_no: poNo
      })
    ]);
    headerRows = postedHeader.data;
    headerError = postedHeader.error;
    lineRows = postedLines.data;
    lineError = postedLines.error;
  }

  if (headerError || !headerRows || headerRows.length === 0) {
    document.getElementById('poSubtitle').textContent = headerError?.message || `Purchase Order ${poNo} not found.`;
    document.getElementById('poContent').classList.remove('hidden');
    return;
  }

  const header = headerRows[0];
  document.getElementById('poNo').textContent = header.po_no || '';
  document.getElementById('poVendor').textContent = header.vendor_name || header.vendor_code || '';
  // Blank on POs raised before the header carried a warehouse, and on any whose lines span
  // several - the lines themselves still name one each.
  document.getElementById('poWarehouse').textContent = header.warehouse_name || '-';
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
