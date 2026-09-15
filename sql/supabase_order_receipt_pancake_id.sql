-- Per direct follow-up request: show the Pancake ("Online Order") id alongside the internal order
-- number, both on the portal receipt page (docs/online-order-receipt.html) and in the AI Bot's
-- payment-confirmation chat text (buildOrderPaymentAck, supabase/functions/facebook-messenger-
-- webhook/index.ts). This is just the short display id (e.g. "91364") - NOT Pancake's order_link,
-- which stays excluded per the earlier explicit "dont share the pancake link" decision
-- (sql/supabase_automated_order_portal_receipt.sql).
--
-- Adds a new pancake_order_id column to all three receipt-shaped functions so the wrapper's
-- "select * from ..." composition keeps working (public_get_order_receipt requires both branches
-- to return identical column sets):
--   * public_get_automated_order_receipt - AutomatedOrders."PancakeOrderId" (distinct from
--     "OrderNo" - e.g. "AO-00008" vs Pancake's own "91364"). Null until the order has synced.
--   * public_get_online_order_receipt - OnlineOrders has no separate Pancake id column; "OrderID"
--     IS the Pancake-facing id for a synced order (confirmed via supabase_orders_sync_tables.sql's
--     admin_list_online_orders, which already compares it directly against AutomatedOrders.
--     PancakeReceiptNo) - so pancake_order_id here is just the same value as order_id, exposed
--     under this column too for a consistent field name on the client.

drop function if exists public.public_get_automated_order_receipt(text);

create or replace function public.public_get_automated_order_receipt(p_order_no text)
returns table(
  order_id text,
  pancake_order_id text,
  order_date date,
  customer_name text,
  shipping_address text,
  status_label text,
  warehouse_name text,
  warehouse_address text,
  delivery_fee numeric,
  money_to_collect numeric,
  amount_paid numeric,
  discount numeric,
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
  select * into v_order from public."AutomatedOrders" where "OrderNo" = v_order_no;
  if not found then
    return;
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
    order_id := v_order_no;
    pancake_order_id := v_order."PancakeOrderId"::text;
    order_date := v_order."CreatedAtUtc"::date;
    customer_name := v_order."CustomerName"::text;
    shipping_address := case when v_order."FulfillmentType" = 'Delivery' then v_order."DeliveryAddress"::text else null end;
    status_label := v_status_label;
    warehouse_name := v_warehouse_name;
    warehouse_address := v_warehouse_address;
    delivery_fee := 0;
    money_to_collect := v_order."EstimatedTotal";
    amount_paid := v_amount_paid;
    discount := 0;
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
    order_id := v_order_no;
    pancake_order_id := v_order."PancakeOrderId"::text;
    order_date := v_order."CreatedAtUtc"::date;
    customer_name := v_order."CustomerName"::text;
    shipping_address := case when v_order."FulfillmentType" = 'Delivery' then v_order."DeliveryAddress"::text else null end;
    status_label := v_status_label;
    warehouse_name := v_warehouse_name;
    warehouse_address := v_warehouse_address;
    delivery_fee := 0;
    money_to_collect := v_order."EstimatedTotal";
    amount_paid := v_amount_paid;
    discount := 0;
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

grant execute on function public.public_get_automated_order_receipt(text) to anon;

-- ---------------------------------------------------------------------------
-- public_get_online_order_receipt: redefined only to add pancake_order_id (= order_id - see file
-- header). Body otherwise identical to sql/supabase_chatbot_online_order_receipt.sql.
-- ---------------------------------------------------------------------------

drop function if exists public.public_get_online_order_receipt(text);

create or replace function public.public_get_online_order_receipt(p_order_id text)
returns table(
  order_id text,
  pancake_order_id text,
  order_date date,
  customer_name text,
  shipping_address text,
  status_label text,
  warehouse_name text,
  warehouse_address text,
  delivery_fee numeric,
  money_to_collect numeric,
  amount_paid numeric,
  discount numeric,
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
  v_order_date date;
  v_customer_name text;
  v_shipping_address text;
  v_status_label text;
  v_warehouse_name text;
  v_warehouse_address text;
  v_delivery_fee numeric;
  v_money_to_collect numeric;
  v_amount_paid numeric;
  v_discount numeric;
  v_balance numeric;
  v_note_print text;
  v_order_id text := trim(p_order_id);
  v_line record;
  v_line_no int := 0;
begin
  select
    o."Date", o."CustomerName"::text, o."ShippingAddress"::text,
    coalesce(
      case
        when lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted') then 'Confirmed'
        when lower(trim(coalesce(o."Status", ''))) = 'printed' then 'Printed'
        when lower(trim(coalesce(o."Status", ''))) in ('to ship', 'packing', 'packed') then 'To Ship'
        when lower(trim(coalesce(o."Status", ''))) in ('shipped', 'delivered', '2') then 'Shipped'
        when lower(trim(coalesce(o."Status", ''))) in ('canceled', 'cancelled') then 'Cancelled'
        else null
      end,
      o."Status"
    )::text,
    w."Name"::text, w."Address"::text,
    o."DeliveryFee", o."MoneyToCollect", o."AmountPaid", o."Discount", o."Balance",
    nullif(trim(o."NotePrint"::text), '')
    into v_order_date, v_customer_name, v_shipping_address, v_status_label,
         v_warehouse_name, v_warehouse_address,
         v_delivery_fee, v_money_to_collect, v_amount_paid, v_discount, v_balance, v_note_print
  from public."OnlineOrders" o
  left join public."Warehouses" w on w."ID" = o."LocationID"
  where o."OrderID" = v_order_id
    and o."ReceivedAtShop" is not true;

  if not found then
    return;
  end if;

  for v_line in
    select l."Description"::text as description, l."Quantity" as quantity,
           coalesce(l."GrossAmount", l."NetAmount", l."Price" * l."Quantity") as amount,
           nullif(trim(l."Note"::text), '') as note
    from public."OnlineOrderLines" l
    where l."OrderID" = v_order_id
    order by l."LineID"
  loop
    v_line_no := v_line_no + 1;
    order_id := v_order_id;
    pancake_order_id := v_order_id;
    order_date := v_order_date;
    customer_name := v_customer_name;
    shipping_address := v_shipping_address;
    status_label := v_status_label;
    warehouse_name := v_warehouse_name;
    warehouse_address := v_warehouse_address;
    delivery_fee := v_delivery_fee;
    money_to_collect := v_money_to_collect;
    amount_paid := v_amount_paid;
    discount := v_discount;
    balance := v_balance;
    note_print := v_note_print;
    line_no := v_line_no;
    line_description := v_line.description;
    line_quantity := v_line.quantity;
    line_amount := v_line.amount;
    line_note := v_line.note;
    return next;
  end loop;

  if v_line_no = 0 then
    order_id := v_order_id;
    pancake_order_id := v_order_id;
    order_date := v_order_date;
    customer_name := v_customer_name;
    shipping_address := v_shipping_address;
    status_label := v_status_label;
    warehouse_name := v_warehouse_name;
    warehouse_address := v_warehouse_address;
    delivery_fee := v_delivery_fee;
    money_to_collect := v_money_to_collect;
    amount_paid := v_amount_paid;
    discount := v_discount;
    balance := v_balance;
    note_print := v_note_print;
    line_no := null;
    line_description := null;
    line_quantity := null;
    line_amount := null;
    line_note := null;
    return next;
  end if;
end;
$$;

grant execute on function public.public_get_online_order_receipt(text) to anon;

-- ---------------------------------------------------------------------------
-- public_get_order_receipt: redefined only to widen its return table to match the new
-- pancake_order_id column both branches above now return.
-- ---------------------------------------------------------------------------

drop function if exists public.public_get_order_receipt(text);

create or replace function public.public_get_order_receipt(p_order_no text)
returns table(
  order_id text,
  pancake_order_id text,
  order_date date,
  customer_name text,
  shipping_address text,
  status_label text,
  warehouse_name text,
  warehouse_address text,
  delivery_fee numeric,
  money_to_collect numeric,
  amount_paid numeric,
  discount numeric,
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
  v_row_count int;
begin
  return query select * from public.public_get_automated_order_receipt(p_order_no);
  get diagnostics v_row_count = row_count;
  if v_row_count > 0 then
    return;
  end if;

  return query select * from public.public_get_online_order_receipt(p_order_no);
end;
$$;

grant execute on function public.public_get_order_receipt(text) to anon;
