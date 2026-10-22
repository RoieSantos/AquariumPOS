// Public "Pay Online" page (pay.html?order=AO-00012) - shows an order's balance and sends the customer
// to a Xendit checkout for the 50% down payment or the full balance. The amount is decided server side
// (Edge Function xendit-create-invoice -> _xendit_prepare_invoice, sql/supabase_xendit_payments.sql);
// this page only picks the order and "Down payment" / "Full balance". Xendit returns the customer here
// with &result=success|failed, and the webhook (xendit-webhook) records the payment on the order.
//
// Master switch: while XenditSettings.Enabled is off (or the SQL isn't installed yet) customers only see
// "not available yet". A super user logged into the portal in this browser can still use the page to
// test - their login is sent along and re-checked server side (_xendit_prepare_invoice).
let currentOrderRef = null;
let staffTester = null;

function peso(value) {
  return '₱' + Number(value || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function setText(id, text) {
  document.getElementById(id).textContent = text;
}

function showMsg(id, kind, text) {
  const el = document.getElementById(id);
  el.className = `pay-msg ${kind}`;
  el.textContent = text;
}

function hide(id) {
  document.getElementById(id).classList.add('hidden');
}

async function fetchOrder(orderRef) {
  const { data, error } = await supabaseClient.rpc('public_get_order_for_online_payment', { p_order_ref: orderRef });
  if (error) throw new Error(error.message);
  return (data && data[0]) || null;
}

function renderOrder(order) {
  currentOrderRef = order.order_ref;
  setText('orderRef', order.order_ref);
  setText('orderStatus', order.order_status || '-');
  const showOnline = order.online_order_id && order.online_order_id !== order.order_ref;
  document.getElementById('onlineOrderRow').classList.toggle('hidden', !showOnline);
  if (showOnline) setText('onlineOrderId', '#' + order.online_order_id);

  const items = document.getElementById('orderItems');
  items.innerHTML = '';
  (order.items || []).forEach((item) => {
    const li = document.createElement('li');
    li.textContent = `${item.qty} × ${item.name}`;
    items.appendChild(li);
  });

  setText('orderTotal', peso(order.total));
  setText('orderPaid', peso(order.amount_paid));
  setText('orderBalance', peso(order.balance));

  const downBtn = document.getElementById('payDownBtn');
  const fullBtn = document.getElementById('payFullBtn');
  if (order.can_pay) {
    hide('cannotPay');
    document.getElementById('payActions').classList.remove('hidden');
    const hasDown = Number(order.down_payment_due) > 0 && Number(order.down_payment_due) < Number(order.balance);
    downBtn.classList.toggle('hidden', !hasDown);
    downBtn.textContent = `Pay 50% down payment - ${peso(order.down_payment_due)}`;
    fullBtn.textContent = `Pay full balance - ${peso(order.balance)}`;
    // The primary (filled) style goes on whichever option is first.
    fullBtn.className = `land-btn ${hasDown ? 'land-btn-secondary' : 'land-btn-primary'}`;
  } else {
    hide('payActions');
    showMsg('cannotPay', 'warn', order.reason || 'This order can\'t be paid online.');
  }
  document.getElementById('orderCard').classList.remove('hidden');
}

async function lookup(orderRef) {
  hide('lookupError');
  hide('payError');
  const btn = document.getElementById('lookupBtn');
  btn.disabled = true;
  try {
    const order = await fetchOrder(orderRef);
    if (!order) {
      hide('orderCard');
      showMsg('lookupError', 'err', `We couldn't find order "${orderRef}". Check the Order ID on your confirmation and try again.`);
      return null;
    }
    renderOrder(order);
    const url = new URL(window.location.href);
    url.searchParams.set('order', order.order_ref);
    window.history.replaceState(null, '', url.pathname + '?' + url.searchParams.toString());
    return order;
  } catch (err) {
    showMsg('lookupError', 'err', 'Could not load the order: ' + err.message);
    return null;
  } finally {
    btn.disabled = false;
  }
}

async function startPayment(purpose) {
  hide('payError');
  const buttons = [document.getElementById('payDownBtn'), document.getElementById('payFullBtn')];
  buttons.forEach((b) => { b.disabled = true; });
  const clicked = purpose === 'Down payment' ? buttons[0] : buttons[1];
  const label = clicked.textContent;
  clicked.textContent = 'Opening secure checkout...';
  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/xendit-create-invoice`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        orderRef: currentOrderRef,
        purpose,
        returnUrl: window.location.origin + window.location.pathname,
        staffUsername: staffTester?.username,
        staffPassword: staffTester?.password
      })
    });
    const body = await response.json().catch(() => null);
    if (!response.ok || !body?.invoiceUrl) throw new Error(body?.error || `Request failed (${response.status}).`);
    window.location.href = body.invoiceUrl;
  } catch (err) {
    showMsg('payError', 'err', err.message);
    buttons.forEach((b) => { b.disabled = false; });
    clicked.textContent = label;
  }
}

// Back from Xendit after paying: the webhook usually lands within seconds - poll until the order shows
// the payment, then show the updated balance.
async function waitForPaymentRecorded(orderRef, startedAt) {
  for (let attempt = 0; attempt < 12; attempt++) {
    const order = await fetchOrder(orderRef).catch(() => null);
    if (order && order.last_payment_status === 'Paid' && new Date(order.last_payment_at) >= startedAt) {
      renderOrder(order);
      showMsg('resultMsg', 'ok', `Payment received - thank you! Order ${order.order_ref} now has a balance of ${peso(order.balance)}.`);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 2500));
  }
  showMsg('resultMsg', 'ok', 'Payment received - thank you! It can take a few minutes to show on your order. No need to pay again.');
  const order = await fetchOrder(orderRef).catch(() => null);
  if (order) renderOrder(order);
}

async function xenditEnabled() {
  try {
    const { data, error } = await supabaseClient.rpc('public_get_xendit_settings');
    return !error && !!(data && data[0] && data[0].enabled);
  } catch {
    return false;
  }
}

// The portal login (js/auth.js) of a super user, from this tab or another open portal tab.
async function findStaffTester() {
  let session = getPortalSession();
  if (!session) session = await requestSessionFromOtherTabs();
  return session && session.isSuperUser && session.password ? session : null;
}

(async function init() {
  const params = new URLSearchParams(window.location.search);
  const orderRef = (params.get('order') || '').trim();
  const result = params.get('result');

  if (!(await xenditEnabled())) {
    staffTester = await findStaffTester();
    if (!staffTester) {
      hide('lookupForm');
      showMsg('resultMsg', 'warn', 'Online payment isn\'t available yet. Please pay by GCash or bank transfer as shown on your order confirmation, or contact us for help.');
      return;
    }
    showMsg('staffBanner', 'warn', `STAFF TEST - online payment is switched OFF for customers. Only you (${staffTester.username}) can use this page.`);
  }

  document.getElementById('lookupForm').addEventListener('submit', (event) => {
    event.preventDefault();
    const value = document.getElementById('orderInput').value.trim();
    if (value) lookup(value);
  });
  document.getElementById('payDownBtn').addEventListener('click', () => startPayment('Down payment'));
  document.getElementById('payFullBtn').addEventListener('click', () => startPayment('Full balance'));

  if (!orderRef) return;
  document.getElementById('orderInput').value = orderRef;

  if (result === 'success') {
    showMsg('resultMsg', 'ok', 'Payment received - updating your order...');
    // Payments made in the last hour count (the customer may have taken a while at the checkout).
    await lookup(orderRef);
    waitForPaymentRecorded(orderRef, new Date(Date.now() - 60 * 60 * 1000));
    return;
  }
  if (result === 'failed') {
    showMsg('resultMsg', 'warn', 'The payment was not completed. You can try again below, or message us if you need help.');
  }
  await lookup(orderRef);
})();
