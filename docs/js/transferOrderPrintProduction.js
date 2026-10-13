// Printable "Production Order" - a simplified, larger-font warehouse packing list (Item/Variant/
// Description/Qty To Ship only, no letterhead or signature block), linked from the "Print
// Production Order" button on the Transfer Orders Manage modal (see js/transferOrders.js's
// printProductionOrder()). Printing this layout is what locks the transfer order (see
// supabase_transfer_orders_lock_column.sql) - the lock itself is set by transferOrders.js before
// this tab even opens, not by this page, so this file only ever reads/displays.
let currentSession = null;

function formatDate(value) {
  if (!value) return '';
  const d = new Date(value);
  if (isNaN(d.getTime())) return value;
  return d.toLocaleDateString();
}

// The line's saved "Qty To Ship" (what the Manage modal filled from stock or someone typed) - i.e.
// only what's actually going out on this shipment, so production assembles just that. Capped at
// what's still unshipped. A line whose Qty To Ship was never saved (null - e.g. ledger posting off
// and nobody typed one) falls back to the full unshipped balance. Lines at 0 are dropped entirely.
function lineRemainingToShip(l) {
  const remaining = Math.max(0, (Number(l['Qty To Transfer']) || 0) - (Number(l['Qty Shipped']) || 0));
  const toShip = l['Qty To Ship'];
  if (toShip === null || toShip === undefined || toShip === '') return remaining;
  return Math.min(remaining, Math.max(0, Number(toShip) || 0));
}

// Assemble-to-Order lines: the exploded BOM (components x quantity still to ship) printed right under
// the parent line, so the warehouse has a build list. Comes from staff_get_transfer_bom
// (supabase_assemble_to_order.sql) - empty if that isn't set up, in which case nothing extra prints.
let bomByLineNo = new Map();

// Component totals are scaled to this print's Qty To Ship (the RPC's total_required is based on the
// full unshipped balance).
function bomRowsHtml(lineNo, qty) {
  const components = bomByLineNo.get(String(lineNo));
  if (!components || components.length === 0) return '';
  return `
    <tr>
      <td colspan="4">
        <strong>Assemble to order - build list:</strong>
        ${components.map((c) => `<div>&#8627; ${c.component_code} - ${c.component_name}: ${Number(c.qty_per) * qty} (${Number(c.qty_per)} per)</div>`).join('')}
      </td>
    </tr>`;
}

function renderLines(lines) {
  const body = document.getElementById('linesBody');
  const toShip = (lines || [])
    .map((l) => ({ line: l, qty: lineRemainingToShip(l) }))
    .filter((l) => l.qty > 0);

  if (toShip.length === 0) {
    body.innerHTML = '<tr><td colspan="4" class="muted">No lines have a Qty To Ship on this order.</td></tr>';
    return;
  }

  body.innerHTML = toShip
    .map(({ line: l, qty }) => `
      <tr>
        <td>${l['Item No.'] || ''}</td>
        <td>${l['Variant Name'] || ''}</td>
        <td>${l['Description'] || ''}</td>
        <td>${qty}</td>
      </tr>${bomRowsHtml(l['Line No.'], qty)}
    `)
    .join('');
}

async function loadOrder(docNo) {
  const { data: headerRows, error: headerError } = await supabaseClient
    .from('Transfer_Header')
    .select('*')
    .eq('"No."', docNo)
    .limit(1);

  if (headerError || !headerRows || headerRows.length === 0) {
    document.getElementById('orderTitle').textContent = `Production Order ${docNo}`;
    document.getElementById('linesBody').innerHTML = `<tr><td class="error-text">${headerError?.message || 'Transfer order not found.'}</td></tr>`;
    document.getElementById('orderContent').classList.remove('hidden');
    return;
  }

  const header = headerRows[0];
  document.getElementById('orderTitle').textContent = `Production Order ${header['No.']}`;
  document.getElementById('orderSubtitle').textContent = header['Description'] || '';
  document.getElementById('fromWarehouse').textContent = header['From Warehouse'] || '';
  document.getElementById('toWarehouse').textContent = header['To Warehouse'] || '';
  document.getElementById('requestedDate').textContent = formatDate(header['Requested Date']);
  document.getElementById('requestedBy').textContent = header['Requested By'] || '';
  document.getElementById('targetDeliveryDate').textContent = formatDate(header['Estimated Delivery Date']);

  const { data: lineRows, error: lineError } = await supabaseClient
    .from('Transfer_Line')
    .select('*')
    .eq('"Document No."', docNo)
    .order('"Line No."', { ascending: true });

  if (lineError) {
    document.getElementById('linesBody').innerHTML = `<tr><td class="error-text">${lineError.message}</td></tr>`;
  } else {
    const { data: bomRows, error: bomError } = await supabaseClient.rpc('staff_get_transfer_bom', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_document_no: docNo
    });
    bomByLineNo = new Map();
    if (!bomError) {
      (bomRows || []).forEach((r) => {
        if (!bomByLineNo.has(String(r.line_no))) bomByLineNo.set(String(r.line_no), []);
        bomByLineNo.get(String(r.line_no)).push(r);
      });
    }
    renderLines(lineRows || []);
  }

  document.getElementById('orderContent').classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Transfer Orders');

  const docNo = new URLSearchParams(window.location.search).get('no');
  if (!docNo) {
    document.getElementById('orderTitle').textContent = 'Production Order';
    document.getElementById('linesBody').innerHTML = '<tr><td class="error-text">Missing ?no= parameter.</td></tr>';
    document.getElementById('orderContent').classList.remove('hidden');
    return;
  }

  document.getElementById('printBtn').addEventListener('click', () => window.print());

  await loadOrder(docNo);
})();
