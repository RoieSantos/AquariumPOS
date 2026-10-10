// Public, no-login "Invoice" view of an order (?order=<AutomatedOrders.OrderNo or an Online Order id>) -
// sent from GMA Conversations' "Send to customer: Invoice" (sendReceiptToCustomer in
// docs/js/gmaConversations.js). Same public_get_order_receipt RPC and the same sheet as
// online-order-receipt.html's Order Confirmation (js/orderDocument.js), just titled INVOICE.
async function loadInvoice() {
  const orderId = new URLSearchParams(window.location.search).get('order');
  const statusEl = document.getElementById('statusMessage');
  if (!orderId) {
    statusEl.textContent = 'No order number given - open this page from the link shared with you.';
    return;
  }

  const [{ data, error }, info] = await Promise.all([
    supabaseClient.rpc('public_get_order_receipt', { p_order_no: orderId }),
    fetchCompanyInfo()
  ]);
  if (error) {
    statusEl.textContent = 'Could not load this invoice right now - please try again shortly.';
    return;
  }
  if (!data || data.length === 0) {
    statusEl.textContent = `No order found matching "${orderId}".`;
    return;
  }

  statusEl.classList.add('hidden');
  document.title = renderOrderDocument(document.getElementById('docContainer'), data, info, 'invoice');
  document.getElementById('toolbar').classList.remove('hidden');
}

loadInvoice();
