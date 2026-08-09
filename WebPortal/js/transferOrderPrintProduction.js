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

// Only what's still left to ship (Qty To Transfer minus whatever's already gone out) - not the
// original full requested Qty To Transfer. Showing the full original amount on a reprint after a
// partial shipment would tell production to prepare items that already shipped, which is exactly
// the confusion this print exists to avoid. Lines with nothing left to ship are dropped entirely.
function lineRemainingToShip(l) {
  return Math.max(0, (Number(l['Qty To Transfer']) || 0) - (Number(l['Qty Shipped']) || 0));
}

function renderLines(lines) {
  const body = document.getElementById('linesBody');
  const toShip = (lines || [])
    .map((l) => ({ line: l, qty: lineRemainingToShip(l) }))
    .filter((l) => l.qty > 0);

  if (toShip.length === 0) {
    body.innerHTML = '<tr><td colspan="4" class="muted">Nothing left to ship on this order.</td></tr>';
    return;
  }

  body.innerHTML = toShip
    .map(({ line: l, qty }) => `
      <tr>
        <td>${l['Item No.'] || ''}</td>
        <td>${l['Variant Name'] || ''}</td>
        <td>${l['Description'] || ''}</td>
        <td>${qty}</td>
      </tr>
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
