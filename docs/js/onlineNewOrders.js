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

  const info = [
    `<strong>Phone:</strong> ${escapeHtml(order.customer_phone || '-')}`,
    `<strong>${escapeHtml(order.fulfillment_type || 'Fulfillment')}:</strong> ${escapeHtml(order.fulfillment_type === 'Delivery' ? (order.delivery_address || '(no address)') : (order.location || '-'))}`,
    `<strong>Branch:</strong> ${escapeHtml(order.location || '-')}`,
    `<strong>Created:</strong> ${newOrderDate(order.created_at_utc)}${order.created_by ? ` by ${escapeHtml(order.created_by)}` : ''}`
  ];
  if (order.notes) info.push(`<strong>Notes:</strong> ${escapeHtml(order.notes)}`);
  document.getElementById('newOrderInfo').innerHTML = info.join('<br>');
  document.getElementById('newOrderLines').innerHTML = '<tr><td colspan="4" class="cell-msg">Loading...</td></tr>';
  document.getElementById('newOrderFoot').innerHTML = '';
  dialog.classList.remove('hidden');

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
  document.getElementById('newOrderLines').innerHTML = lines.length === 0
    ? '<tr><td colspan="4" class="cell-msg">No items.</td></tr>'
    : lines.map((l) => `
      <tr>
        <td>${escapeHtml(l.item_name || '')}${l.variant_name && l.variant_name !== l.item_name ? ` <span class="muted">(${escapeHtml(l.variant_name)})</span>` : ''}
          ${l.notes ? `<div class="muted" style="font-size:12px; white-space:pre-wrap;">${escapeHtml(l.notes)}</div>` : ''}</td>
        <td class="num">${escapeHtml(String(l.quantity ?? ''))}</td>
        <td class="num">${newOrderMoney(l.price)}</td>
        <td class="num">${newOrderMoney(Number(l.quantity || 0) * Number(l.price || 0))}</td>
      </tr>`).join('');

  const total = Number(order.estimated_total || 0);
  const paid = Number(order.amount_paid || 0);
  document.getElementById('newOrderFoot').innerHTML = `
    <tr><td colspan="3" class="num"><strong>Total</strong></td><td class="num"><strong>${newOrderMoney(total)}</strong></td></tr>
    <tr><td colspan="3" class="num">Paid</td><td class="num">${newOrderMoney(paid)}</td></tr>
    <tr><td colspan="3" class="num">Balance</td><td class="num">${newOrderMoney(total - paid)}</td></tr>`;
}

function closeNewOrderDialog() {
  document.getElementById('newOrderDialog').classList.add('hidden');
  openNewOrderNo = null;
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
