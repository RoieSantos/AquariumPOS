-- Order Confirmation receipt redesign (docs/online-order-receipt.html - the "Order Confirmation" link /
-- send from GMA Conversations and the bot's receiptUrl). Per "can you beautify the receipt we building in
-- the conversations? i want it to be like this with the details of the warehouse".
--
-- 1. Warehouses."ContactNo" - a contact number per branch, edited on Warehouse Setup next to Address
--    (admin_list_warehouses returns it, admin_update_warehouse_contact saves it).
-- 2. The three receipt functions gain four columns the new layout shows:
--      sales_staff       - who confirmed the order (OnlineOrders."ConfirmedBy"), else who created it
--                          (display name); the AI bot shows as "Online Assistant".
--      customer_phone    - receiver's phone.
--      warehouse_contact - the branch's ContactNo (above).
--      line_code         - each line's item code / SKU.
--    Same bodies as supabase_order_receipt_pancake_id.sql otherwise. The return type changes, so all three
--    are dropped and re-created; the wrapper still requires both branches to return identical columns.
--
-- Run AFTER supabase_order_receipt_pancake_id.sql and supabase_warehouse_address_geocode.sql. Safe to
-- re-run. Needs online-order-receipt.html's new layout and warehouseSetup.js ?v=contact1.

-- ---------------------------------------------------------------------------
-- 1. Warehouse contact number

alter table public."Warehouses" add column if not exists "ContactNo" varchar(100);

drop function if exists public.admin_list_warehouses(text, text, int, int);

create or replace function public.admin_list_warehouses(p_admin_username text, p_admin_password text, p_page int default 1, p_page_size int default 50)
returns table(
  id text,
  name text,
  is_production_warehouse boolean,
  is_stock_warehouse boolean,
  is_active boolean,
  sales_target numeric,
  synced_at_utc timestamptz,
  address text,
  geocode_status text,
  contact_no text,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "ID"::text, "Name"::text, "IsProductionWarehouse", "IsStockWarehouse", "IsActive", "SalesTarget", "SyncedAtUtc",
           "Address"::text, "GeocodeStatus"::text, "ContactNo"::text,
           count(*) over()
    from public."Warehouses"
    order by "Name"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_warehouses(text, text, int, int) to anon;

drop function if exists public.admin_update_warehouse_contact(text, text, text, text);

create or replace function public.admin_update_warehouse_contact(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text,
  p_contact_no text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  update public."Warehouses"
  set "ContactNo" = nullif(trim(p_contact_no), '')
  where "ID" = p_warehouse_id;
end;
$$;

grant execute on function public.admin_update_warehouse_contact(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 2. Receipt functions (wrapper first - it calls the other two)

drop function if exists public.public_get_order_receipt(text);
drop function if exists public.public_get_automated_order_receipt(text);
drop function if exists public.public_get_online_order_receipt(text);

-- 2a. GMA / bot / Order Now orders (AutomatedOrders).
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
  line_note text,
  sales_staff text,
  customer_phone text,
  warehouse_contact text,
  line_code text
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
  v_warehouse_contact text;
  v_amount_paid numeric;
  v_status_label text;
  v_sales_staff text;
  v_line record;
  v_line_no int := 0;
begin
  select * into v_order from public."AutomatedOrders" where "OrderNo" = v_order_no;
  if not found then
    return;
  end if;

  select w."Name"::text, w."Address"::text, w."ContactNo"::text
  into v_warehouse_name, v_warehouse_address, v_warehouse_contact
  from public."Warehouses" w
  where w."Name" ilike '%' || coalesce(nullif(trim(v_order."Location"), ''), 'Amaya') || '%'
  order by w."Name"
  limit 1;

  v_warehouse_name := coalesce(v_warehouse_name, v_order."Location");

  select coalesce(sum(p."Amount"), 0) into v_amount_paid
  from public."AutomatedOrderPayments" p
  where p."OrderNo" = v_order_no;

  -- Who confirmed it (once it's in Online Orders), else who created it.
  select coalesce(
           (select nullif(trim(oo."ConfirmedBy"), '') from public."OnlineOrders" oo where oo."OrderID" = v_order."PancakeReceiptNo"),
           case when v_order."UpdatedBy" = 'AI Bot' then 'Online Assistant' end,
           (select nullif(trim(s."DisplayName"), '') from public."StaffUsers" s where s."Username" = v_order."UpdatedBy"),
           nullif(trim(v_order."UpdatedBy"), ''))
    into v_sales_staff;

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
           nullif(trim(l."Notes"::text), '') as note,
           coalesce(nullif(trim(l."ItemCode"), ''), nullif(trim(l."CategoryCode"), ''))::text as code
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
    sales_staff := v_sales_staff;
    customer_phone := v_order."CustomerPhone"::text;
    warehouse_contact := v_warehouse_contact;
    line_code := v_line.code;
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
    sales_staff := v_sales_staff;
    customer_phone := v_order."CustomerPhone"::text;
    warehouse_contact := v_warehouse_contact;
    line_code := null;
    return next;
  end if;
end;
$$;

grant execute on function public.public_get_automated_order_receipt(text) to anon;

-- 2b. Pancake-synced Online Orders (walk-ins excluded, as before).
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
  line_note text,
  sales_staff text,
  customer_phone text,
  warehouse_contact text,
  line_code text
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
  v_warehouse_contact text;
  v_delivery_fee numeric;
  v_money_to_collect numeric;
  v_amount_paid numeric;
  v_discount numeric;
  v_balance numeric;
  v_note_print text;
  v_sales_staff text;
  v_customer_phone text;
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
    w."Name"::text, w."Address"::text, w."ContactNo"::text,
    o."DeliveryFee", o."MoneyToCollect", o."AmountPaid", o."Discount", o."Balance",
    nullif(trim(o."NotePrint"::text), ''),
    coalesce(nullif(trim(o."ConfirmedBy"), ''), nullif(trim(o."CreatedBy"), ''))::text,
    o."ShippingPhone"::text
    into v_order_date, v_customer_name, v_shipping_address, v_status_label,
         v_warehouse_name, v_warehouse_address, v_warehouse_contact,
         v_delivery_fee, v_money_to_collect, v_amount_paid, v_discount, v_balance, v_note_print,
         v_sales_staff, v_customer_phone
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
           nullif(trim(l."Note"::text), '') as note,
           coalesce(nullif(trim(l."product_display_id"), ''), nullif(trim(l."ItemCode"), ''))::text as code
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
    sales_staff := v_sales_staff;
    customer_phone := v_customer_phone;
    warehouse_contact := v_warehouse_contact;
    line_code := v_line.code;
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
    sales_staff := v_sales_staff;
    customer_phone := v_customer_phone;
    warehouse_contact := v_warehouse_contact;
    line_code := null;
    return next;
  end if;
end;
$$;

grant execute on function public.public_get_online_order_receipt(text) to anon;

-- 2c. Wrapper: AutomatedOrders first, then Online Orders.
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
  line_note text,
  sales_staff text,
  customer_phone text,
  warehouse_contact text,
  line_code text
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
