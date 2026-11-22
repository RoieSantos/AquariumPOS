// Printable Stock On Hand list, scoped by whatever filters were active on the report itself -
// linked from Stock On Hand's "Print" button (js/stockOnHand.js), per direct request ("can I
// request a printout per vendor? so I can order stocks"). Carries the vendor/category/warehouse/
// search filters through as query params rather than re-picking them here, so "Print" always
// prints exactly what's currently on screen.
//
// The Quantity column shows the value staff typed into Stock On Hand's own editable "Quantity"
// input per row (js/stockOnHand.js), handed off via localStorage (shared per-origin across tabs -
// keyed the same way, "item_code|warehouse_id"). Per direct follow-up request, this REPLACES the
// system's own Quantity On Hand figure on the printout entirely - the printout is meant to read as
// an order sheet (how much to order), not a mirror of current stock. A blank Notes column is left
// for anything handwritten while calling/visiting the vendor.
let currentSession = null;

//
// When nothing was typed into any Quantity box, the printout is a plain stock list instead (e.g.
// printing a branch's count after a physical inventory): the column becomes "On Hand" and shows
// the ledger balance. "Hide items with no stock" on the report is carried through as ?hideZero=1.
function renderRows(rows, enteredQuantities, showOnHand) {
  const tbody = document.getElementById('printTableBody');
  if (!rows || rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No stock records match these filters.</td></tr>';
    return;
  }

  tbody.innerHTML = rows
    .map((r) => {
      const key = `${r.item_code}|${r.warehouse_id}`;
      const qty = showOnHand ? Number(r.remain_quantity || 0).toLocaleString() : (enteredQuantities[key] || '');
      return `
      <tr>
        <td>${r.item_code || ''}</td>
        <td>${r.item_name || ''}</td>
        <td>${r.variant_name || ''}</td>
        <td>${r.warehouse_name || ''}</td>
        <td style="text-align:right;">${qty}</td>
        <td></td>
      </tr>
    `;
    })
    .join('');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Stock On Hand');
  await renderCompanyLetterhead('companyLetterhead');

  document.getElementById('printBtn').addEventListener('click', () => window.print());

  const params = new URLSearchParams(window.location.search);
  const warehouseId = params.get('warehouse') || null;
  const categoryCode = params.get('category') || null;
  const vendorCode = params.get('vendor') || null;
  const vendorName = params.get('vendorName') || null;
  const search = params.get('search') || null;

  document.getElementById('printTitle').textContent = vendorName ? `Stock Order - ${vendorName}` : 'Stock On Hand';
  const subtitleParts = [];
  if (categoryCode) subtitleParts.push(`Category: ${params.get('categoryName') || categoryCode}`);
  if (warehouseId) subtitleParts.push(`Warehouse: ${params.get('warehouseName') || warehouseId}`);
  subtitleParts.push(`Printed: ${new Date().toLocaleString()}`);
  document.getElementById('printSubtitle').textContent = subtitleParts.join(' | ');

  const { data, error } = await supabaseClient.rpc('staff_list_item_warehouse_stock', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_warehouse_id: warehouseId,
    p_search: search,
    p_category_code: categoryCode,
    p_vendor_code: vendorCode
  });

  if (error) {
    document.getElementById('printTableBody').innerHTML = `<tr><td class="error-text">${error.message}</td></tr>`;
    return;
  }

  let enteredQuantities = {};
  try {
    enteredQuantities = JSON.parse(localStorage.getItem('stockOnHandEnteredQuantities') || '{}');
  } catch {
    enteredQuantities = {};
  }

  let rows = data || [];
  if (params.get('hideZero') === '1') rows = rows.filter((r) => Number(r.remain_quantity) !== 0);
  rows.sort((a, b) => String(a.item_name || '').localeCompare(String(b.item_name || '')));

  const showOnHand = !rows.some((r) => enteredQuantities[`${r.item_code}|${r.warehouse_id}`]);
  if (showOnHand) document.getElementById('qtyHeader').textContent = 'On Hand';

  renderRows(rows, enteredQuantities, showOnHand);
})();
