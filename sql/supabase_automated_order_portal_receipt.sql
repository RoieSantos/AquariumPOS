-- Per direct follow-up request: the AI Bot was sharing Pancake's OWN order-confirmation link
-- (AutomatedOrders."PancakeOrderLink") after placing an order - explicitly rejected: "dont share
-- the pancake link.. i want to share the actual receipt rendered on our portal if possible".
--
-- docs/online-order-receipt.html already exists as a public, no-login, portal-rendered receipt
-- page (see supabase_chatbot_online_order_receipt.sql) - but it's backed by
-- public_get_online_order_receipt, which only reads OnlineOrders/OnlineOrderLines. That table is
-- the one-way Pancake -> Supabase sync MIRROR (supabase_orders_sync_tables.sql), not the table an
-- AI-bot-created order actually lands in the instant create_order runs
-- (AutomatedOrders/AutomatedOrderLines) - there is real lag before/unless a pushed order syncs
-- back into OnlineOrders, so reusing that RPC directly for a just-created AO-xxxxx order would
-- often 404 right when the bot needs to share it.
--
-- This adds the AutomatedOrders-flavored equivalent (public_get_automated_order_receipt, same
-- flat "one row per line, header repeated" shape as public_get_online_order_receipt so
-- docs/online-order-receipt.html can render either with no branching), plus a combined
-- public_get_order_receipt wrapper that tries Automated first, then falls back to Online - so
-- one page, one URL shape, and one RPC name work for both order systems, the same "try both,
-- don't make the customer know which system their order lives in" pattern chatbot-engine.ts's
-- get_order_status tool already uses.

drop function if exists public.public_get_automated_order_receipt(text);

create or replace function public.public_get_automated_order_receipt(p_order_no text)
returns table(
  order_id text,
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
-- Combined lookup: tries Automated Orders first (AO-xxxxx - what the AI bot and staff's GMA
-- Conversations Create Order tab both produce), then falls back to Online Orders (a Pancake
-- order number/receipt no). docs/online-order-receipt.html and chatbot-engine.ts's get_order_status
-- both call this ONE function instead of picking which underlying RPC to call themselves.
-- ---------------------------------------------------------------------------

drop function if exists public.public_get_order_receipt(text);

create or replace function public.public_get_order_receipt(p_order_no text)
returns table(
  order_id text,
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
