// Printable single Transfer Order (?no=TR-...), linked from the "Print" button on the Transfer
// Orders Manage modal (see js/transferOrders.js). Looks in the live Transfer_Header/Transfer_Line
// tables first, then falls back to Posted_Transfer_Header/Posted_Transfer_Line (see
// supabase_posted_transfer_orders_tables.sql) so a fully-received order (already archived and
// removed from the live tables) can still be printed.
let currentSession = null;

function formatDate(value) {
  if (!value) return '';
  const d = new Date(value);
  if (isNaN(d.getTime())) return value;
  return d.toLocaleDateString();
}

// What is going out on this shipment: the Qty To Ship saved on the line, or - when none was
// entered - everything still unshipped (the same default the Manage modal's Qty To Ship box shows).
function qtyToShip(line) {
  const saved = line['Qty To Ship'];
  if (saved !== null && saved !== undefined && saved !== '') return saved;
  return lineRemainingToShip(line);
}

function lineRemainingToShip(line) {
  return Math.max(0, (Number(line['Qty To Transfer']) || 0) - (Number(line['Qty Shipped']) || 0));
}

// What the Manage modal's Qty To Ship box shows for the line: never more than is still unshipped.
// The saved Qty To Ship is left holding the last shipped amount once Ship is clicked, so an
// already fully-shipped line (blank box in the modal) would otherwise still read as "to ship".
function pendingQtyToShip(line) {
  return Math.min(lineRemainingToShip(line), Math.max(0, Number(qtyToShip(line)) || 0));
}

// onlyToShip: drop lines with nothing going out on the next shipment (Qty To Ship 0, or already
// fully shipped), so the printout lists just what is on this shipment. Live orders only - a Posted
// (fully-received) order is printed as the complete record, and so is a live order with nothing
// left to ship on any line.
function renderLines(lines, onlyToShip) {
  const body = document.getElementById('linesBody');
  if (!lines || lines.length === 0) {
    body.innerHTML = '<tr><td colspan="7" class="muted">No line items.</td></tr>';
    return;
  }

  const hasUnshipped = lines.some((l) => lineRemainingToShip(l) > 0);
  const pendingOnly = onlyToShip && hasUnshipped;
  if (pendingOnly) {
    lines = lines.filter((l) => pendingQtyToShip(l) > 0);
    if (lines.length === 0) {
      body.innerHTML = '<tr><td colspan="7" class="muted">No lines with a Qty To Ship on this order.</td></tr>';
      return;
    }
  }

  body.innerHTML = lines
    .map((l) => `
      <tr>
        <td>${l['Item No.'] || ''}</td>
        <td>${l['Variant Name'] || ''}</td>
        <td>${l['Description'] || ''}</td>
        <td>${l['Qty To Transfer'] ?? ''}</td>
        <td>${pendingOnly ? pendingQtyToShip(l) : qtyToShip(l)}</td>
        <td>${l['Qty Shipped'] ?? ''}</td>
        <td>${l['Qty Received'] ?? ''}</td>
      </tr>
    `)
    .join('');
}

async function loadOrder(docNo) {
  let { data: headerRows, error: headerError } = await supabaseClient
    .from('Transfer_Header')
    .select('*')
    .eq('"No."', docNo)
    .limit(1);
  if (headerError) {
    document.getElementById('linesBody').innerHTML = `<tr><td class="error-text">${headerError.message}</td></tr>`;
    return;
  }

  let lineTable = 'Transfer_Line';
  if (!headerRows || headerRows.length === 0) {
    // Not in the live table - try the Posted archive (fully-received orders live there instead).
    lineTable = 'Posted_Transfer_Line';
    const posted = await supabaseClient
      .from('Posted_Transfer_Header')
      .select('*')
      .eq('"No."', docNo)
      .limit(1);
    if (posted.error) {
      document.getElementById('linesBody').innerHTML = `<tr><td class="error-text">${posted.error.message}</td></tr>`;
      return;
    }
    headerRows = posted.data;
  }

  if (!headerRows || headerRows.length === 0) {
    document.getElementById('orderTitle').textContent = `Transfer Order ${docNo}`;
    document.getElementById('linesBody').innerHTML = '<tr><td class="error-text">Transfer order not found.</td></tr>';
    document.getElementById('orderContent').classList.remove('hidden');
    return;
  }

  const header = headerRows[0];
  document.getElementById('orderTitle').textContent = `Transfer Order ${header['No.']}`;
  document.getElementById('orderSubtitle').textContent =
    `${header['Description'] || ''}${header['Description'] ? ' - ' : ''}Status: ${header['Status'] || ''}`;
  document.getElementById('fromWarehouse').textContent = header['From Warehouse'] || '';
  document.getElementById('toWarehouse').textContent = header['To Warehouse'] || '';
  document.getElementById('requestedDate').textContent = formatDate(header['Requested Date']);
  document.getElementById('transferDate').textContent = formatDate(header['Transfer Date']);
  document.getElementById('receiveDate').textContent = formatDate(header['Receive Date']);
  document.getElementById('requestedBy').textContent = header['Requested By'] || '';
  document.getElementById('shippedBy').textContent = header['Shipped By'] || '';

  const { data: lineRows, error: lineError } = await supabaseClient
    .from(lineTable)
    .select('*')
    .eq('"Document No."', docNo)
    .order('"Line No."', { ascending: true });

  if (lineError) {
    document.getElementById('linesBody').innerHTML = `<tr><td class="error-text">${lineError.message}</td></tr>`;
  } else {
    renderLines(lineRows || [], lineTable === 'Transfer_Line');
  }

  document.getElementById('orderContent').classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Transfer Orders');
  await renderCompanyLetterhead('companyLetterhead');

  const docNo = new URLSearchParams(window.location.search).get('no');
  if (!docNo) {
    document.getElementById('orderTitle').textContent = 'Transfer Order';
    document.getElementById('linesBody').innerHTML = '<tr><td class="error-text">Missing ?no= parameter.</td></tr>';
    document.getElementById('orderContent').classList.remove('hidden');
    return;
  }

  document.getElementById('printBtn').addEventListener('click', () => window.print());

  await loadOrder(docNo);
})();
