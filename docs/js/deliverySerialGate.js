// Delivery Receipt / Invoice only after a proper To Ship with every serial tagged - per "they just print it
// and did not do proper to-ship". staff_get_delivery_stop_print_block
// (sql/supabase_delivery_receipt_serial_gate.sql) says why not (or null = OK); used by delivery.js
// (Print / Print Invoice) and by delivery-receipt.html / invoice.html themselves, so a saved link is
// blocked too. Resolves to null = OK to print, else the message to show. Until the SQL is run it lets
// printing through.
async function deliveryStopSerialBlock(session, stopId) {
  const { data, error } = await supabaseClient.rpc('staff_get_delivery_stop_print_block', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_stop_id: stopId
  });
  if (error) {
    if (/schema cache|could not find the function|does not exist/i.test(error.message)) {
      console.warn('Delivery print check not set up - run sql/supabase_delivery_receipt_serial_gate.sql');
      return null;
    }
    return `Could not check this order, so it can't be printed yet: ${error.message}`;
  }
  return data || null;
}
