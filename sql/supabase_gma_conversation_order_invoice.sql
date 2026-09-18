-- Per direct follow-up request: a "print receipt" feature for GMA Conversations orders, split into
-- two documents (per direct instruction, matching how this portal already distinguishes them
-- elsewhere - see invoice.html vs online-order-receipt.html):
--
-- "Order Confirmation" - docs/online-order-receipt.html already covers this exactly: public,
-- no-login, already renders an AutomatedOrders order (via public_get_order_receipt - see
-- supabase_automated_order_portal_receipt.sql) with its own Print button. No new SQL/pages needed -
-- GMA Conversations just needs a link/button to it, added in docs/js/gmaConversations.js.
--
-- "Invoice" - a more formal, staff-only document (Sales Staff, phone, location/branch address - the
-- kind of detail a customer-facing link shouldn't carry) - no existing page fits an AutomatedOrders
-- order (invoice.html is Delivery-Stop-specific, keyed by DeliveryStops.StopID, an entirely
-- different domain). This adds a dedicated, staff-authenticated RPC for a new
-- docs/gma-order-invoice.html page, reusing every .delivery-receipt-*/.invoice-* CSS class already
-- in css/styles.css (shared with invoice.html/delivery-receipt.html) rather than inventing new
-- print styling.

drop function if exists public.admin_get_automated_order_invoice(text, text, text);

create or replace function public.admin_get_automated_order_invoice(
  p_admin_username text,
  p_admin_password text,
  p_order_no text
)
returns table(
  order_no text,
  order_date date,
  customer_name text,
  customer_phone text,
  shipping_address text,
  location text,
  warehouse_name text,
  warehouse_address text,
  sales_staff text,
  status_label text,
  total numeric,
  amount_paid numeric,
  balance numeric,
  note_print text,
  line_no int,
  line_description text,
  line_quantity numeric,
  line_amount numeric,
  line_note text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."AutomatedOrders"%rowtype;
  v_order_no text := trim(p_order_no);
  v_warehouse_name text;
  v_warehouse_address text;
  v_amount_paid numeric;
  v_status_label text;
  v_line record;
  v_line_no int := 0;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_order from public."AutomatedOrders" where "OrderNo" = v_order_no;
  if not found then
    raise exception 'Order % not found.', v_order_no;
  end if;

  select w."Name"::text, w."Address"::text
  into v_warehouse_name, v_warehouse_address
  from public."Warehouses" w
  where w."Name" ilike '%' || coalesce(nullif(trim(v_order."Location"), ''), 'Amaya') || '%'
  order by w."Name"
  limit 1;

  v_warehouse_name := coalesce(v_warehouse_name, v_order."Location");

  select coalesce(sum(p."Amount"), 0) into v_amount_paid
  from public."AutomatedOrderPayments" p
  where p."OrderNo" = v_order_no;

  v_status_label := case v_order."Status"
    when 'New' then 'Order Received - Pending Confirmation'
    when 'Contacted' then 'Contacted'
    when 'Confirmed' then 'Confirmed'
    when 'Completed' then 'Completed'
    when 'Cancelled' then 'Cancelled'
    else v_order."Status"
  end;

  for v_line in
    select l."ItemName"::text as description, l."Quantity" as quantity,
           (l."Price" * l."Quantity") as amount,
           nullif(trim(l."Notes"::text), '') as note
    from public."AutomatedOrderLines" l
    where l."OrderNo" = v_order_no
    order by l."EntryNo"
  loop
    v_line_no := v_line_no + 1;
    order_no := v_order_no;
    order_date := v_order."CreatedAtUtc"::date;
    customer_name := v_order."CustomerName"::text;
    customer_phone := v_order."CustomerPhone"::text;
    shipping_address := case when v_order."FulfillmentType" = 'Delivery' then v_order."DeliveryAddress"::text else 'Pickup' end;
    location := v_order."Location"::text;
    warehouse_name := v_warehouse_name;
    warehouse_address := v_warehouse_address;
    sales_staff := v_order."UpdatedBy"::text;
    status_label := v_status_label;
    total := v_order."EstimatedTotal";
    amount_paid := v_amount_paid;
    balance := v_order."EstimatedTotal" - v_amount_paid;
    note_print := nullif(trim(v_order."Notes"::text), '');
    line_no := v_line_no;
    line_description := v_line.description;
    line_quantity := v_line.quantity;
    line_amount := v_line.amount;
    line_note := v_line.note;
    return next;
  end loop;

  if v_line_no = 0 then
    order_no := v_order_no;
    order_date := v_order."CreatedAtUtc"::date;
    customer_name := v_order."CustomerName"::text;
    customer_phone := v_order."CustomerPhone"::text;
    shipping_address := case when v_order."FulfillmentType" = 'Delivery' then v_order."DeliveryAddress"::text else 'Pickup' end;
    location := v_order."Location"::text;
    warehouse_name := v_warehouse_name;
    warehouse_address := v_warehouse_address;
    sales_staff := v_order."UpdatedBy"::text;
    status_label := v_status_label;
    total := v_order."EstimatedTotal";
    amount_paid := v_amount_paid;
    balance := v_order."EstimatedTotal" - v_amount_paid;
    note_print := nullif(trim(v_order."Notes"::text), '');
    line_no := null;
    line_description := null;
    line_quantity := null;
    line_amount := null;
    line_note := null;
    return next;
  end if;
end;
$$;

grant execute on function public.admin_get_automated_order_invoice(text, text, text) to anon;
