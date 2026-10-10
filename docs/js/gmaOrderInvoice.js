// Staff print Invoice for an order (?order=<AutomatedOrders.OrderNo>), linked from the "Invoice" link on
// each order card in GMA Conversations (docs/js/gmaConversations.js). Same sheet as the Order
// Confirmation and the public Invoice (js/orderDocument.js), titled INVOICE, backed by the same
// public_get_order_receipt (sql/supabase_order_receipt_letterhead.sql - it now carries Sales Staff,
// receiver phone and the branch contact this page used admin_get_automated_order_invoice for). Kept
// behind login with the portal topnav since staff print it from Conversations.
let currentSession = null;

async function loadInvoice(orderNo) {
  const errorEl = document.getElementById('loadError');

  const [{ data, error }, info] = await Promise.all([
    supabaseClient.rpc('public_get_order_receipt', { p_order_no: orderNo }),
    fetchCompanyInfo()
  ]);

  if (error || !data || data.length === 0) {
    errorEl.textContent = (error && error.message) || `No order found matching "${orderNo}".`;
    errorEl.classList.remove('hidden');
    return;
  }

  document.title = renderOrderDocument(document.getElementById('docContainer'), data, info, 'invoice');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Conversations');

  const orderNo = new URLSearchParams(window.location.search).get('order');
  if (!orderNo) {
    document.getElementById('loadError').textContent = 'Missing ?order= parameter.';
    document.getElementById('loadError').classList.remove('hidden');
    return;
  }

  document.getElementById('printBtn').addEventListener('click', () => window.print());

  await loadInvoice(orderNo);
})();
