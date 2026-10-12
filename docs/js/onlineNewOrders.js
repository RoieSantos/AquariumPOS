// Online Orders "New" tab - per "maybe we create a new layer or status NEW.. before the confirmed status
// so all new created that is not yet confirmed will go there". Lists the orders from conversations that
// are waiting to be confirmed (AI bot + GMA "+ New Order"), from staff_list_new_online_orders
// (sql/supabase_online_orders_new_tab.sql). They aren't OnlineOrders rows yet: Confirm Order
// (admin_confirm_bot_order, sql/supabase_bot_orders_portal_confirm.sql) creates the real order, which
// then shows under Confirmed like any other. Replaces the old Online Page Orders page.
//
// Loaded after js/onlineOrders.js and uses its globals (currentSession, escapeHtml, sendGmaMessage) and
// js/pagination.js. onlineOrders.js's init() calls initNewOrdersTab() once the session is ready.

let newOrdersActive = false;
let newOrdersPage = 1;
let newOrdersPageSize = 50;
let newOrdersGeneration = 0;
let newOrdersByNo = new Map();
let selectedNewOrderNo = null;
let openNewOrderNo = null;
// The open order's lines as loaded (admin_list_automated_order_lines), and the Edit-mode draft of them
// (null when not editing).
let openNewOrderLines = [];
let newOrderEditLines = null;
let newOrderSearchResults = [];
let newOrderVariantProduct = null;
let newOrderVariantResults = [];
// Action-bar buttons hidden while the New tab is showing, restored when leaving it.
let newOrdersHiddenCmds = [];

function newOrderMoney(value) {
  return Number(value || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function newOrderDate(value) {
  if (!value) return '';
  return new Date(value).toLocaleString('en-PH', { month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' });
}

function initNewOrdersTab(eligible) {
  if (!eligible) return;
  const tab = document.getElementById('newOrdersTab');
  tab.classList.remove('hidden');

  // Capture phase, so onlineOrders.js's own status-bar click handler never sees a click on the New tab
  // (it would treat it as a status filter). Any other tab leaves the New view first, then that handler
  // runs as usual.
  document.getElementById('statusSummaryBar').addEventListener('click', (event) => {
    const pill = event.target.closest('.status-summary-pill');
    if (!pill) return;
    if (pill === tab) {
      event.stopPropagation();
      if (newOrdersActive) leaveNewOrdersView(true);
      else enterNewOrdersView();
      return;
    }
    if (newOrdersActive) leaveNewOrdersView(false);
  }, true);

  const body = document.getElementById('newOrdersBody');
  body.addEventListener('click', (event) => {
    const link = event.target.closest('[data-open-new]');
    if (link) {
      event.preventDefault();
      selectNewOrderRow(link.dataset.openNew);
      openNewOrderDialog(link.dataset.openNew);
      return;
    }
    const row = event.target.closest('tr[data-new-order]');
    if (row) selectNewOrderRow(row.dataset.newOrder);
  });
  body.addEventListener('dblclick', (event) => {
    const row = event.target.closest('tr[data-new-order]');
    if (row) openNewOrderDialog(row.dataset.newOrder);
  });

  document.getElementById('newOpenBtn').addEventListener('click', () => selectedNewOrderNo && openNewOrderDialog(selectedNewOrderNo));
  document.getElementById('newConfirmBtn').addEventListener('click', () => selectedNewOrderNo && confirmNewOrder(selectedNewOrderNo));
  document.getElementById('newCancelBtn').addEventListener('click', () => selectedNewOrderNo && cancelNewOrder(selectedNewOrderNo));
  document.getElementById('refreshOrdersBtn').addEventListener('click', () => {
    if (newOrdersActive) loadNewOrders();
    else loadNewOrdersCount();
  });

  let searchTimer = null;
  document.getElementById('orderSearchInput').addEventListener('input', () => {
    if (!newOrdersActive) return;
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => { newOrdersPage = 1; loadNewOrders(); }, 300);
  });

  document.getElementById('newOrderConfirmBtn').addEventListener('click', () => openNewOrderNo && confirmNewOrder(openNewOrderNo));
  document.getElementById('newOrderCancelOrderBtn').addEventListener('click', () => openNewOrderNo && cancelNewOrder(openNewOrderNo));
  document.getElementById('newOrderCloseBtn').addEventListener('click', closeNewOrderDialog);
  document.getElementById('closeNewOrderBtn').addEventListener('click', closeNewOrderDialog);
  initNewOrderEdit();
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !document.getElementById('newOrderDialog').classList.contains('hidden')) closeNewOrderDialog();
  });

  loadNewOrdersCount();
}

function enterNewOrdersView() {
  newOrdersActive = true;
  document.querySelectorAll('#statusSummaryBar .status-summary-pill').forEach((pill) => {
    pill.classList.toggle('active', pill.id === 'newOrdersTab');
  });
  document.getElementById('flatOrdersView').classList.add('hidden');
  document.getElementById('newOrdersView').classList.remove('hidden');
  document.getElementById('filterPaneBtn').classList.add('hidden');

  newOrdersHiddenCmds = [];
  document.querySelectorAll('#orderCmdbar > *').forEach((el) => {
    if (el.classList.contains('new-cmd')) {
      el.classList.remove('hidden');
    } else if (el.id !== 'refreshOrdersBtn' && !el.classList.contains('hidden')) {
      el.classList.add('hidden');
      newOrdersHiddenCmds.push(el);
    }
  });

  newOrdersPage = 1;
  loadNewOrders();
}

// restoreList: true when the New tab itself was clicked again (no other tab takes over), so the
// regular list's active-tab highlight is put back too.
function leaveNewOrdersView(restoreList) {
  newOrdersActive = false;
  document.getElementById('newOrdersView').classList.add('hidden');
  document.getElementById('flatOrdersView').classList.remove('hidden');
  document.getElementById('filterPaneBtn').classList.remove('hidden');
  document.getElementById('newOrdersTab').classList.remove('active');
  document.querySelectorAll('#orderCmdbar .new-cmd').forEach((el) => el.classList.add('hidden'));
  newOrdersHiddenCmds.forEach((el) => el.classList.remove('hidden'));
  newOrdersHiddenCmds = [];
  if (restoreList && typeof updateStatusPillActiveState === 'function') updateStatusPillActiveState();
}

async function fetchNewOrders(page, pageSize) {
  return supabaseClient.rpc('staff_list_new_online_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: newOrdersActive ? (document.getElementById('orderSearchInput').value.trim() || null) : null,
    p_page: page,
    p_page_size: pageSize
  });
}

function setNewOrdersCount(count) {
  document.getElementById('statusCountNew').textContent = count === null ? '-' : String(count);
}

async function loadNewOrdersCount() {
  const { data, error } = await fetchNewOrders(1, 1);
  if (error) {
    // Quietly '-' until sql/supabase_online_orders_new_tab.sql is run.
    console.warn('staff_list_new_online_orders:', error.message);
    setNewOrdersCount(null);
    return;
  }
  setNewOrdersCount(Number(data?.[0]?.total_count || 0));
}

async function loadNewOrders() {
  const myGeneration = ++newOrdersGeneration;
  const body = document.getElementById('newOrdersBody');
  const { data, error } = await fetchNewOrders(newOrdersPage, newOrdersPageSize);
  if (myGeneration !== newOrdersGeneration) return;

  if (error) {
    const msg = /could not find the function|does not exist/i.test(error.message || '')
      ? 'The New tab isn\'t set up in the database yet - run sql/supabase_online_orders_new_tab.sql.'
      : error.message;
    body.innerHTML = `<tr><td colspan="11" class="cell-msg error-text">${escapeHtml(msg)}</td></tr>`;
    return;
  }

  const rows = data || [];
  newOrdersByNo = new Map(rows.map((o) => [o.order_no, o]));
  if (selectedNewOrderNo && !newOrdersByNo.has(selectedNewOrderNo)) selectedNewOrderNo = null;
  // Only the unfiltered list's total is the tab count - a search narrows the rows, not the count.
  if (!document.getElementById('orderSearchInput').value.trim()) setNewOrdersCount(Number(rows[0]?.total_count || 0));

  body.innerHTML = rows.length === 0
    ? '<tr><td colspan="11" class="cell-msg">No new orders waiting to be confirmed.</td></tr>'
    : rows.map((o) => {
      const balance = Number(o.estimated_total || 0) - Number(o.amount_paid || 0);
      return `
        <tr class="clickable-row${o.order_no === selectedNewOrderNo ? ' selected' : ''}" data-new-order="${escapeHtml(o.order_no)}">
          <td><a class="bc-doc-no" href="#" data-open-new="${escapeHtml(o.order_no)}" title="Open this order">${escapeHtml(o.order_no)}</a></td>
          <td>${newOrderDate(o.created_at_utc)}</td>
          <td>${escapeHtml(o.created_by || '')}</td>
          <td>${escapeHtml(o.customer_name || '')}</td>
          <td>${escapeHtml(o.customer_phone || '')}</td>
          <td>${escapeHtml(o.fulfillment_type || '')}</td>
          <td>${escapeHtml(o.location || '')}</td>
          <td title="${escapeHtml(o.items_summary || '')}">${escapeHtml(o.items_summary || '')}</td>
          <td class="num">${newOrderMoney(o.estimated_total)}</td>
          <td class="num">${newOrderMoney(o.amount_paid)}</td>
          <td class="num">${newOrderMoney(balance)}</td>
        </tr>`;
    }).join('');
  updateNewOrderActions();

  renderPaginationBar(
    document.getElementById('newOrdersPaginationBar'),
    { page: newOrdersPage, pageSize: newOrdersPageSize, totalCount: rows[0]?.total_count || 0 },
    {
      onPageChange: (page) => { newOrdersPage = page; loadNewOrders(); },
      onPageSizeChange: (size) => { newOrdersPageSize = size; newOrdersPage = 1; loadNewOrders(); }
    }
  );
}

function selectNewOrderRow(orderNo) {
  selectedNewOrderNo = orderNo;
  document.querySelectorAll('#newOrdersBody tr[data-new-order]').forEach((tr) => {
    tr.classList.toggle('selected', tr.dataset.newOrder === orderNo);
  });
  updateNewOrderActions();
}

function updateNewOrderActions() {
  const has = Boolean(selectedNewOrderNo && newOrdersByNo.has(selectedNewOrderNo));
  ['newOpenBtn', 'newConfirmBtn', 'newCancelBtn'].forEach((id) => { document.getElementById(id).disabled = !has; });
}

async function openNewOrderDialog(orderNo) {
  const order = newOrdersByNo.get(orderNo);
  if (!order) return;
  openNewOrderNo = orderNo;
  const dialog = document.getElementById('newOrderDialog');
  document.getElementById('newOrderError').classList.add('hidden');
  document.getElementById('newOrderTitle').textContent = `${order.order_no} · ${order.customer_name || ''}`;

  const delivery = order.fulfillment_type === 'Delivery';
  const info = [
    ['Phone', escapeHtml(order.customer_phone || '-')],
    ['Branch', escapeHtml(order.location || '-')],
    ['Fulfillment', delivery ? 'Delivery' : 'Pickup'],
    ['Created', `${newOrderDate(order.created_at_utc)}${order.created_by ? ` by ${escapeHtml(order.created_by)}` : ''}`]
  ];
  if (order.customer_email) info.push(['Email', escapeHtml(order.customer_email)]);
  if (delivery) info.push(['Delivery Address', escapeHtml(order.delivery_address || '(no address)'), true]);
  if (order.notes) info.push(['Notes', escapeHtml(order.notes), true]);
  setNewOrderEditMode(false);
  openNewOrderLines = [];
  document.getElementById('newOrderEditBtn').disabled = true;
  document.getElementById('newOrderInfo').innerHTML = `<div class="no-info-grid">${info.map(([label, value, wide]) =>
    `<div class="no-info-item${wide ? ' no-edit-wide' : ''}"><span class="no-info-label">${label}</span><span class="no-info-value">${value}</span></div>`).join('')}</div>`;
  document.getElementById('newOrderLines').innerHTML = '<tr><td colspan="4" class="cell-msg">Loading...</td></tr>';
  document.getElementById('newOrderFoot').innerHTML = '';
  dialog.classList.remove('hidden');
  // After a payment change: reload the list (Paid / Balance) and redraw this dialog with it.
  renderAoPayments(document.getElementById('newOrderPayments'), orderNo, async () => {
    await loadNewOrders();
    if (openNewOrderNo === orderNo && !newOrderEditLines) {
      const fresh = newOrdersByNo.get(orderNo);
      if (fresh) {
        const fee = fresh.fulfillment_type === 'Delivery' ? Number(fresh.delivery_fee || 0) : 0;
        renderNewOrderFoot(Number(fresh.estimated_total || 0) - fee, fee, Number(fresh.amount_paid || 0));
      }
    }
  });

  const { data, error } = await supabaseClient.rpc('admin_list_automated_order_lines', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_no: orderNo
  });
  if (openNewOrderNo !== orderNo) return;
  if (error) {
    document.getElementById('newOrderLines').innerHTML = `<tr><td colspan="4" class="cell-msg error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  const lines = data || [];
  openNewOrderLines = lines;
  document.getElementById('newOrderEditBtn').disabled = false;
  document.getElementById('newOrderLines').innerHTML = lines.length === 0
    ? '<tr><td colspan="4" class="cell-msg">No items.</td></tr>'
    : lines.map((l) => `
      <tr>
        <td><div class="no-line-name">${escapeHtml(l.item_name || '')}${l.variant_name && l.variant_name !== l.item_name ? ` <span class="muted">(${escapeHtml(l.variant_name)})</span>` : ''}</div>
          ${l.notes ? `<div class="no-line-note">${escapeHtml(l.notes)}</div>` : ''}</td>
        <td class="num">${escapeHtml(String(l.quantity ?? ''))}</td>
        <td class="num">${newOrderMoney(l.price)}</td>
        <td class="num">${newOrderMoney(Number(l.quantity || 0) * Number(l.price || 0))}</td>
      </tr>`).join('');

  const fee = delivery ? Number(order.delivery_fee || 0) : 0;
  renderNewOrderFoot(Number(order.estimated_total || 0) - fee, fee, Number(order.amount_paid || 0));
}

// Totals block under the items (view and edit): Items subtotal, Delivery Fee, Total, Paid, Balance.
function renderNewOrderFoot(items, fee, paid) {
  const total = items + fee;
  const balance = total - paid;
  const row = (label, value, cls) => `<tr class="${cls || ''}"><td colspan="3" class="num">${label}</td><td class="num">${value}</td></tr>`;
  document.getElementById('newOrderFoot').innerHTML = [
    fee > 0 ? row('Items', newOrderMoney(items), 'no-foot-first') : '',
    fee > 0 ? row('Delivery Fee', newOrderMoney(fee)) : '',
    row('Total', newOrderMoney(total), 'no-foot-total' + (fee > 0 ? '' : ' no-foot-first')),
    row('Paid', newOrderMoney(paid)),
    row('Balance', newOrderMoney(balance), 'no-foot-balance' + (balance > 0 ? ' is-due' : balance < 0 ? ' is-over' : ''))
  ].join('');
}

function closeNewOrderDialog() {
  if (newOrderEditLines && !confirm('Discard your changes to this order?')) return;
  setNewOrderEditMode(false);
  document.getElementById('newOrderDialog').classList.add('hidden');
  openNewOrderNo = null;
}

// ---------------------------------------------------------------------------
// Edit mode - per "can the user also modify the order here.. only for new orders". Same save as GMA
// Conversations' Edit Order (admin_update_automated_order), which replaces the whole header + every line,
// so each field is prefilled and the lines keep their item / variant codes. Only orders waiting to be
// confirmed are ever on this tab, and the server refuses anything already confirmed.

// Switches the dialog's buttons / search bar between view and edit. Leaving edit drops the draft lines.
function setNewOrderEditMode(on) {
  if (!on) newOrderEditLines = null;
  document.getElementById('newOrderEditSearch').classList.toggle('hidden', !on);
  document.getElementById('newOrderHint').classList.toggle('hidden', on);
  document.getElementById('newOrderPaymentsSection').classList.toggle('hidden', on);
  ['newOrderEditBtn', 'newOrderConfirmBtn', 'newOrderCancelOrderBtn'].forEach((id) => document.getElementById(id).classList.toggle('hidden', on));
  ['newOrderSaveBtn', 'newOrderDiscardBtn'].forEach((id) => document.getElementById(id).classList.toggle('hidden', !on));
  document.getElementById('newOrderSaveBtn').disabled = false;
  document.getElementById('newOrderProductSearch').value = '';
  document.getElementById('newOrderProductResults').classList.add('hidden');
}

function startNewOrderEdit() {
  const order = newOrdersByNo.get(openNewOrderNo);
  if (!order) return;
  document.getElementById('newOrderError').classList.add('hidden');
  setNewOrderEditMode(true);
  newOrderEditLines = openNewOrderLines.map((l) => ({
    category_code: l.category_code || null,
    item_code: l.item_code || null,
    item_name: l.item_name,
    price: Number(l.price) || 0,
    quantity: Number(l.quantity) || 1,
    note: l.notes || '',
    variation_id: l.variation_id || null
  }));

  const field = (label, control, wide, id) => `<div class="bc-field${wide ? ' no-edit-wide' : ''}"${id ? ` id="${id}"` : ''}><label>${label}</label>${control}</div>`;
  document.getElementById('newOrderInfo').innerHTML = `
    <div class="no-section-title">Customer &amp; delivery</div>
    <div class="no-edit-grid">
      ${field('Customer Name', '<input type="text" id="noeName">')}
      ${field('Phone', '<input type="text" id="noePhone" placeholder="09171234567">')}
      ${field('Email (optional)', '<input type="text" id="noeEmail">')}
      ${field('Branch', '<select id="noeLocation"><option value="Amaya">Amaya</option><option value="GMA">GMA</option></select>')}
      ${field('Fulfillment', '<select id="noeFulfillment"><option value="Pickup">Pickup</option><option value="Delivery">Delivery</option></select>')}
      ${field('Delivery Fee', '<input type="number" min="0" step="0.01" id="noeDeliveryFee" placeholder="0.00">', false, 'noeDeliveryFeeRow')}
      ${field('Delivery Address', '<input type="text" id="noeAddress">', true, 'noeAddressRow')}
      ${field('Notes (optional)', '<input type="text" id="noeNotes">', true)}
    </div>`;
  document.getElementById('noeName').value = order.customer_name || '';
  document.getElementById('noePhone').value = order.customer_phone || '';
  document.getElementById('noeEmail').value = order.customer_email || '';
  document.getElementById('noeLocation').value = order.location === 'GMA' ? 'GMA' : 'Amaya';
  document.getElementById('noeFulfillment').value = order.fulfillment_type === 'Delivery' ? 'Delivery' : 'Pickup';
  document.getElementById('noeAddress').value = order.delivery_address || '';
  document.getElementById('noeDeliveryFee').value = Number(order.delivery_fee || 0) > 0 ? Number(order.delivery_fee).toFixed(2) : '';
  document.getElementById('noeNotes').value = order.notes || '';
  document.getElementById('noeFulfillment').addEventListener('change', syncNewOrderEditFulfillment);
  document.getElementById('noeDeliveryFee').addEventListener('input', updateNewOrderEditTotals);
  syncNewOrderEditFulfillment();

  renderNewOrderEditLines();
}

function syncNewOrderEditFulfillment() {
  const delivery = document.getElementById('noeFulfillment').value === 'Delivery';
  document.getElementById('noeAddressRow').classList.toggle('hidden', !delivery);
  document.getElementById('noeDeliveryFeeRow').classList.toggle('hidden', !delivery);
  updateNewOrderEditTotals();
}

function newOrderEditFee() {
  if (document.getElementById('noeFulfillment')?.value !== 'Delivery') return 0;
  const fee = parseFloat(document.getElementById('noeDeliveryFee').value);
  return fee > 0 ? fee : 0;
}

function renderNewOrderEditLines() {
  const body = document.getElementById('newOrderLines');
  body.innerHTML = newOrderEditLines.length === 0
    ? '<tr><td colspan="4" class="cell-msg">No items - add a product above.</td></tr>'
    : newOrderEditLines.map((l, i) => `
      <tr>
        <td><div class="no-line-name">${escapeHtml(l.item_name)}</div>
          <textarea class="no-edit-note" rows="1" data-idx="${i}" data-field="note" placeholder="Line note (optional)">${escapeHtml(l.note || '')}</textarea>
          <button type="button" class="no-edit-remove" data-remove="${i}">Remove item</button></td>
        <td class="num"><input type="number" class="no-edit-qty" min="1" step="1" data-idx="${i}" data-field="quantity" value="${l.quantity}"></td>
        <td class="num"><input type="number" class="no-edit-price" min="0" step="0.01" data-idx="${i}" data-field="price" value="${l.price}"></td>
        <td class="num" data-amount="${i}">${newOrderMoney(l.quantity * l.price)}</td>
      </tr>`).join('');
  updateNewOrderEditTotals();
}

function updateNewOrderEditTotals() {
  if (!newOrderEditLines) return;
  const order = newOrdersByNo.get(openNewOrderNo);
  const items = newOrderEditLines.reduce((sum, l) => sum + l.quantity * l.price, 0);
  const fee = newOrderEditFee();
  renderNewOrderFoot(items, fee, Number(order?.amount_paid || 0));
}

// Typing in a qty / price / note box updates that line and the totals in place (no re-render, so the
// box keeps focus).
function onNewOrderEditLineInput(event) {
  const el = event.target;
  if (!newOrderEditLines || el.dataset.idx === undefined) return;
  const line = newOrderEditLines[Number(el.dataset.idx)];
  if (!line) return;
  if (el.dataset.field === 'quantity') line.quantity = Math.max(parseInt(el.value, 10) || 1, 1);
  else if (el.dataset.field === 'price') line.price = Math.max(parseFloat(el.value) || 0, 0);
  else if (el.dataset.field === 'note') line.note = el.value;
  const amountCell = document.querySelector(`#newOrderLines [data-amount="${el.dataset.idx}"]`);
  if (amountCell) amountCell.textContent = newOrderMoney(line.quantity * line.price);
  updateNewOrderEditTotals();
}

function onNewOrderEditLineClick(event) {
  const btn = event.target.closest('[data-remove]');
  if (!btn || !newOrderEditLines) return;
  newOrderEditLines.splice(Number(btn.dataset.remove), 1);
  renderNewOrderEditLines();
}

// Product search - same sources as GMA Conversations' Create Order (staff_search_items_wildcard, then
// public_list_item_variants for a product with variants, shown in the same dropdown).
async function runNewOrderProductSearch(term) {
  const resultsEl = document.getElementById('newOrderProductResults');
  const { data, error } = await supabaseClient.rpc('staff_search_items_wildcard', { p_query: term });
  if (document.getElementById('newOrderProductSearch').value.trim() !== term) return;
  resultsEl.classList.remove('hidden');
  if (error) {
    resultsEl.innerHTML = `<div class="no-edit-result is-msg">${escapeHtml(error.message)}</div>`;
    return;
  }
  newOrderSearchResults = data || [];
  resultsEl.innerHTML = newOrderSearchResults.length === 0
    ? '<div class="no-edit-result is-msg">No matching items.</div>'
    : newOrderSearchResults.map((item, i) => `
      <div class="no-edit-result" data-product="${i}">
        <span>${escapeHtml(item.name)}${item.has_variants ? ' <span class="no-edit-sub">(choose variant)</span>' : ''}</span>
        <span>${newOrderMoney(item.price)}</span>
      </div>`).join('');
}

async function showNewOrderVariants(item) {
  const resultsEl = document.getElementById('newOrderProductResults');
  resultsEl.innerHTML = '<div class="no-edit-result is-msg">Loading variants...</div>';
  const { data, error } = await supabaseClient.rpc('public_list_item_variants', { p_item_code: item.code });
  if (error) {
    resultsEl.innerHTML = `<div class="no-edit-result is-msg">${escapeHtml(error.message)}</div>`;
    return;
  }
  newOrderVariantProduct = item;
  newOrderVariantResults = data || [];
  resultsEl.innerHTML = `<div class="no-edit-result is-msg">${escapeHtml(item.name)} - pick a variant:</div>` + (newOrderVariantResults.length === 0
    ? '<div class="no-edit-result is-msg">No variants found for this product.</div>'
    : newOrderVariantResults.map((v, i) => `
      <div class="no-edit-result" data-variant="${i}">
        <span>${escapeHtml(v.variant_name)}${v.sku ? ` <span class="no-edit-sub">${escapeHtml(v.sku)}</span>` : ''}</span>
        <span>${newOrderMoney(v.price)} <span class="no-edit-sub">${Number(v.quantity_in_stock || 0) > 0 ? `${v.quantity_in_stock} left` : 'Out of stock'}</span></span>
      </div>`).join(''));
}

// Same line naming / dedupe as gmaConversations.js addOrderLineFromProduct.
function addNewOrderEditProduct(item, variant) {
  const variantLabel = variant ? (variant.sku ? `${variant.variant_name} - ${variant.sku}` : variant.variant_name) : null;
  const variationId = variant ? variant.variation_id : null;
  const dedupeKey = variationId || item.code;
  const existing = newOrderEditLines.find((l) => (l.variation_id || l.item_code) === dedupeKey);
  if (existing) {
    existing.quantity += 1;
  } else {
    newOrderEditLines.push({
      category_code: item.category_code,
      item_code: item.code,
      item_name: variant ? `${item.name} (${variantLabel})` : item.name,
      price: Number((variant || item).price || 0),
      quantity: 1,
      note: '',
      variation_id: variationId
    });
  }
  document.getElementById('newOrderProductSearch').value = '';
  document.getElementById('newOrderProductResults').classList.add('hidden');
  renderNewOrderEditLines();
}

async function saveNewOrderEdit() {
  const orderNo = openNewOrderNo;
  if (!orderNo || !newOrderEditLines) return;
  document.getElementById('newOrderError').classList.add('hidden');
  if (newOrderEditLines.length === 0) {
    newOrderActionError('At least one item is required.');
    return;
  }
  const fulfillment = document.getElementById('noeFulfillment').value;
  const saveBtn = document.getElementById('newOrderSaveBtn');
  saveBtn.disabled = true;

  const { error } = await supabaseClient.rpc('admin_update_automated_order', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_no: orderNo,
    p_customer_name: document.getElementById('noeName').value.trim(),
    p_customer_phone: document.getElementById('noePhone').value.trim(),
    p_customer_email: document.getElementById('noeEmail').value.trim() || null,
    p_fulfillment_type: fulfillment,
    p_delivery_address: fulfillment === 'Delivery' ? document.getElementById('noeAddress').value.trim() : null,
    p_notes: document.getElementById('noeNotes').value.trim() || null,
    p_location: document.getElementById('noeLocation').value,
    p_lines: newOrderEditLines.map((l) => ({ ...l, note: (l.note || '').trim() || null })),
    p_delivery_fee: newOrderEditFee()
  });
  if (openNewOrderNo !== orderNo) return;
  if (error) {
    saveBtn.disabled = false;
    newOrderActionError(`Could not save order ${orderNo}: ${error.message}`);
    return;
  }

  setNewOrderEditMode(false);
  await loadNewOrders();
  if (newOrdersByNo.has(orderNo)) openNewOrderDialog(orderNo);
  else closeNewOrderDialog();
}

function initNewOrderEdit() {
  document.getElementById('newOrderEditBtn').addEventListener('click', startNewOrderEdit);
  document.getElementById('newOrderSaveBtn').addEventListener('click', saveNewOrderEdit);
  document.getElementById('newOrderDiscardBtn').addEventListener('click', () => {
    if (openNewOrderNo) openNewOrderDialog(openNewOrderNo);
  });
  const lines = document.getElementById('newOrderLines');
  lines.addEventListener('input', onNewOrderEditLineInput);
  lines.addEventListener('click', onNewOrderEditLineClick);

  const search = document.getElementById('newOrderProductSearch');
  let timer = null;
  search.addEventListener('input', () => {
    clearTimeout(timer);
    const term = search.value.trim();
    if (!term) {
      document.getElementById('newOrderProductResults').classList.add('hidden');
      return;
    }
    timer = setTimeout(() => runNewOrderProductSearch(term), 300);
  });
  search.addEventListener('blur', () => {
    // Delayed so a mousedown on a result has already run.
    setTimeout(() => document.getElementById('newOrderProductResults').classList.add('hidden'), 150);
  });
  search.addEventListener('focus', () => {
    if (search.value.trim() && newOrderSearchResults.length) runNewOrderProductSearch(search.value.trim());
  });
  // mousedown + preventDefault: fires before the search box's blur hides the dropdown.
  document.getElementById('newOrderProductResults').addEventListener('mousedown', (event) => {
    const product = event.target.closest('[data-product]');
    const variant = event.target.closest('[data-variant]');
    if (!product && !variant) return;
    event.preventDefault();
    if (variant) {
      addNewOrderEditProduct(newOrderVariantProduct, newOrderVariantResults[Number(variant.dataset.variant)]);
      return;
    }
    const item = newOrderSearchResults[Number(product.dataset.product)];
    if (item.has_variants) showNewOrderVariants(item);
    else addNewOrderEditProduct(item, null);
  });
}

function newOrderActionError(message) {
  if (openNewOrderNo) {
    const el = document.getElementById('newOrderError');
    el.textContent = message;
    el.classList.remove('hidden');
  } else {
    alert(message);
  }
}

// Confirm Order: admin_confirm_bot_order creates the Online Orders entry (status Confirmed). For a GMA
// conversation order the customer then gets the same "order confirmed" message GMA Conversations sends.
async function confirmNewOrder(orderNo) {
  const order = newOrdersByNo.get(orderNo);
  if (!confirm(`Confirm order ${orderNo}? Check the items, prices and customer details first - it moves to Confirmed.`)) return;

  const { error } = await supabaseClient.rpc('admin_confirm_bot_order', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_no: orderNo
  });
  if (error) {
    newOrderActionError(`Could not confirm order ${orderNo}: ${error.message}`);
    return;
  }

  // Website Alice orders carry a 'web:<visitor>' id (chatbot-web-reply) - not a Messenger user, so no
  // message can be sent there.
  if (order?.gma_psid && !order.gma_psid.startsWith('web:')) {
    const receiptLink = `https://rspetstop.com/online-order-receipt.html?order=${encodeURIComponent(orderNo)}`;
    const { sent, error: sendError } = await sendGmaMessage(order.gma_psid,
      `Your order has been confirmed, Please see receipt for your reference. We will keep you posted on the status of your order. Any concerns please let us know :) #HFK\n${receiptLink}`);
    if (!sent) alert(`Order ${orderNo} is confirmed, but the confirmation message to the customer failed: ${sendError || 'unknown error'}`);
  }

  closeNewOrderDialog();
  selectedNewOrderNo = null;
  await loadNewOrders();
  if (typeof loadStatusSummary === 'function') loadStatusSummary();
}

// Cancel Order: a draft that won't go ahead (wrong order, customer backed out). Sets the bot order's
// status to Cancelled, which drops it off this tab. Nothing was ever created in Online Orders.
async function cancelNewOrder(orderNo) {
  if (!confirm(`Cancel order ${orderNo}? It won't be confirmed and will disappear from New.`)) return;
  const { error } = await supabaseClient.rpc('admin_update_automated_order_status', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_no: orderNo,
    p_status: 'Cancelled'
  });
  if (error) {
    newOrderActionError(`Could not cancel order ${orderNo}: ${error.message}`);
    return;
  }
  closeNewOrderDialog();
  selectedNewOrderNo = null;
  loadNewOrders();
}

// ---------------------------------------------------------------------------
// Payments editor for a portal order (AO-) - per "can we also let the user to modify the payment in the
// order even though its new and confirmed". Used by the New dialog (below the items) and the Online
// Orders card's Payment tab (onlineOrders.js renderOrderCardAoPayments). Lists AutomatedOrderPayments
// with Edit / Delete, plus Add payment (admin_add_automated_order_payment). Edit / Delete:
// sql/supabase_ao_order_payment_edit.sql (New + open confirmed portal orders only, every change logged).
// onChanged runs after a save so the caller can refresh its totals.

const AO_PAY_METHODS = ['Cash', 'GCash', 'BDO', 'Metrobank', 'Bank Transfer', 'Other'];

function aoPayMethodOptions(selected) {
  const list = AO_PAY_METHODS.includes(selected) || !selected ? AO_PAY_METHODS : [...AO_PAY_METHODS, selected];
  return list.map((m) => `<option value="${escapeHtml(m)}"${m === (selected || 'Cash') ? ' selected' : ''}>${escapeHtml(m)}</option>`).join('');
}

function aoPayFormHtml(p) {
  return `
    <div class="ao-pay-form">
      <input type="number" step="0.01" class="ao-pay-amount" placeholder="Amount" value="${p ? escapeHtml(String(Number(p.amount))) : ''}">
      <select class="ao-pay-method">${aoPayMethodOptions(p?.method)}</select>
      <input type="text" class="ao-pay-ref" placeholder="Reference (optional)" maxlength="200" value="${escapeHtml(p?.reference || '')}">
      <button type="button" class="bc-btn bc-btn-primary ao-pay-save" data-pay-save="${p ? p.payment_id : 'new'}">Save</button>
      <button type="button" class="bc-btn ao-pay-cancel" data-pay-cancel>Cancel</button>
    </div>`;
}

function aoPayRender(container) {
  const st = container._aoPay;
  if (st.error) {
    container.innerHTML = `<div class="ao-pay-msg error-text">${escapeHtml(st.error)}</div>`;
    return;
  }
  const rows = st.payments.map((p) => st.editingId === p.payment_id
    ? `<div class="ao-pay-row is-editing">${aoPayFormHtml(p)}</div>`
    : `<div class="ao-pay-row">
        <div class="ao-pay-main">
          <div class="ao-pay-method-label">${escapeHtml(p.method || '')}${p.reference ? ` <span class="ao-pay-sub">&middot; ${escapeHtml(p.reference)}</span>` : ''}</div>
          <div class="ao-pay-sub">${p.recorded_at_utc ? new Date(p.recorded_at_utc).toLocaleString('en-PH', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : ''}${p.recorded_by ? ` by ${escapeHtml(p.recorded_by)}` : ''}</div>
        </div>
        <div class="ao-pay-amount-label">${newOrderMoney(p.amount)}</div>
        <div class="ao-pay-actions">
          <button type="button" class="ao-pay-link" data-pay-edit="${p.payment_id}">Edit</button>
          <button type="button" class="ao-pay-link is-danger" data-pay-delete="${p.payment_id}">Delete</button>
        </div>
      </div>`).join('');
  container.innerHTML = `
    ${rows || '<div class="ao-pay-msg">No payments recorded yet.</div>'}
    ${st.editingId === 'new'
      ? `<div class="ao-pay-row is-editing">${aoPayFormHtml(null)}</div>`
      : '<button type="button" class="ao-pay-add" data-pay-add>+ Add payment</button>'}`;
  container.querySelector('.ao-pay-row.is-editing .ao-pay-amount')?.focus();
}

async function aoPayLoad(container) {
  const st = container._aoPay;
  const orderNo = st.orderNo;
  const { data, error } = await supabaseClient.rpc('admin_list_automated_order_payments', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_no: orderNo
  });
  if (container._aoPay !== st) return;
  st.error = error ? error.message : null;
  st.payments = data || [];
  aoPayRender(container);
}

async function aoPaySave(container, target) {
  const st = container._aoPay;
  const form = target.closest('.ao-pay-form');
  const amount = parseFloat(form.querySelector('.ao-pay-amount').value);
  if (!amount) {
    alert('Enter the payment amount.');
    return;
  }
  const method = form.querySelector('.ao-pay-method').value;
  const reference = form.querySelector('.ao-pay-ref').value.trim() || null;
  target.disabled = true;
  const base = { p_admin_username: currentSession.username, p_admin_password: currentSession.password };
  const { error } = target.dataset.paySave === 'new'
    ? await supabaseClient.rpc('admin_add_automated_order_payment', { ...base, p_order_no: st.orderNo, p_amount: amount, p_method: method, p_reference: reference })
    : await supabaseClient.rpc('admin_update_automated_order_payment', { ...base, p_payment_id: Number(target.dataset.paySave), p_amount: amount, p_method: method, p_reference: reference });
  if (error) {
    target.disabled = false;
    alert(`Could not save the payment: ${error.message}`);
    return;
  }
  st.editingId = null;
  await aoPayLoad(container);
  if (st.onChanged) st.onChanged();
}

async function aoPayDelete(container, paymentId) {
  const st = container._aoPay;
  const p = st.payments.find((x) => x.payment_id === paymentId);
  if (!p || !confirm(`Delete the ${p.method || ''} payment of ${newOrderMoney(p.amount)} on ${st.orderNo}?`)) return;
  const { error } = await supabaseClient.rpc('admin_delete_automated_order_payment', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_payment_id: paymentId
  });
  if (error) {
    alert(`Could not delete the payment: ${error.message}`);
    return;
  }
  await aoPayLoad(container);
  if (st.onChanged) st.onChanged();
}

function renderAoPayments(container, orderNo, onChanged) {
  container._aoPay = { orderNo, onChanged, payments: [], editingId: null, error: null };
  container.innerHTML = '<div class="ao-pay-msg">Loading payments...</div>';
  if (!container.dataset.aoPayBound) {
    container.dataset.aoPayBound = '1';
    container.addEventListener('click', (event) => {
      const st = container._aoPay;
      if (!st) return;
      const t = event.target.closest('button');
      if (!t) return;
      if (t.dataset.payAdd !== undefined) { st.editingId = 'new'; aoPayRender(container); }
      else if (t.dataset.payEdit) { st.editingId = Number(t.dataset.payEdit); aoPayRender(container); }
      else if (t.dataset.payCancel !== undefined) { st.editingId = null; aoPayRender(container); }
      else if (t.dataset.payDelete) aoPayDelete(container, Number(t.dataset.payDelete));
      else if (t.dataset.paySave) aoPaySave(container, t);
    });
  }
  aoPayLoad(container);
}
