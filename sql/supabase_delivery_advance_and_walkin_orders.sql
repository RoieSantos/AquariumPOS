-- Delivery calendar: assign Advance Orders too, and fix walk-in orders - per "can we assign advance
-- orders too?" and "also can you check walk-in orders can be assign?".
--
-- ADVANCE ORDERS. They live in public."AdvanceOrders" (keyed by TransactionNo), not OnlineOrders, and
-- most have no linked online order - but DeliveryStops."OrderID" was a NOT NULL foreign key to
-- OnlineOrders, so they could never be a stop. Now a stop points at exactly ONE of:
--   "OrderID"              -> OnlineOrders (unchanged, FK kept)
--   "AdvanceTransactionNo" -> AdvanceOrders (new, real FK)
-- An advance stop shows everywhere as order "ADV-<TransactionNo>" (calendar, driver view, manifest,
-- receipt, invoice, job order) with its lines from AdvanceOrderLines, Balance as the amount to collect,
-- and the production stage as its status ("Advance - To Ship"). No address is on file for advance
-- orders, so the calendar asks for address / name / phone / notes when one is assigned.
--
-- WALK-IN ORDERS. They were already allowed (POS creates them in Pancake as Shipped, which is in the
-- list), but two things got in the way:
--   1. The assign list hid every order with ForDelivery = true. The Pancake sync overwrites ForDelivery
--      from Pancake's "free shipping" tick on every run, so a free-shipping order (or walk-in) vanished
--      from the list, and an already-scheduled order could re-appear. The list now hides an order only
--      when it actually has a delivery stop.
--   2. The walk-in customer name / phone typed on Online Orders (WalkinCustomerName / WalkinCustomerPhone)
--      weren't used - the calendar showed "POS WALKIN ORDERS". Now they're shown on the assign list,
--      stops, receipt and driver view (a name typed on the stop itself still wins).
--
-- Re-creates (latest versions): admin_list_deliverable_online_orders (supabase_delivery_assign_cancelled_
-- superuser.sql), admin_create_delivery_stop (supabase_delivery_stop_route_tagging.sql),
-- admin_list_delivery_stops + admin_get_delivery_receipt (supabase_delivery_stop_manual_address.sql),
-- _notify_delivery_stop_changed (supabase_delivery_route_change_push.sql).
-- Run AFTER those files and supabase_advance_order_production.sql / supabase_walkin_order_portal_status.sql.
-- Safe to re-run. Needs js/delivery.js ?v=advdeliv1 (reload the Delivery page after running).

-- ---------------------------------------------------------------------------
-- 1. DeliveryStops: an advance order can be the stop's order.

set lock_timeout = '10s';

alter table public."DeliveryStops" add column if not exists "AdvanceTransactionNo" varchar(100)
  references public."AdvanceOrders"("TransactionNo");
alter table public."DeliveryStops" alter column "OrderID" drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'CK_DeliveryStops_OneOrder') then
    alter table public."DeliveryStops" add constraint "CK_DeliveryStops_OneOrder"
      check (num_nonnulls("OrderID", "AdvanceTransactionNo") = 1);
  end if;
end;
$$;

reset lock_timeout;

-- Same "once per date" rule as UQ_DeliveryStops_Order_Date, for advance orders.
create unique index if not exists "UQ_DeliveryStops_Advance_Date"
  on public."DeliveryStops" ("AdvanceTransactionNo", "DeliveryDate")
  where "AdvanceTransactionNo" is not null;

-- ---------------------------------------------------------------------------
-- 2. Assign list: online (incl. walk-in) + advance orders not on the calendar yet.

-- p_sort_column / p_sort_dir: click-to-sort headers on the assign list (order_id / customer_name /
-- status / shipping_address / type, 'asc' | 'desc'). Sorted here, not in the browser, because the
-- list is paged - null = latest update first (the old order).
drop function if exists public.admin_list_deliverable_online_orders(text, text, text, int, int);

create or replace function public.admin_list_deliverable_online_orders(p_admin_username text, p_admin_password text, p_search text default null, p_page int default 1, p_page_size int default 50,
  p_sort_column text default null, p_sort_dir text default 'asc')
returns table(
  order_id text,                 -- OnlineOrders.OrderID, or AdvanceOrders.TransactionNo when source = 'advance'
  source text,                   -- 'online' | 'advance'
  customer_name text,
  status text,
  shipping_address text,
  contact_number text,
  money_to_collect numeric,
  balance numeric,
  estimated_delivery_date date,
  is_walk_in boolean,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_sort text := lower(coalesce(p_sort_column, ''));
  v_desc boolean := lower(coalesce(p_sort_dir, 'asc')) = 'desc';
  v_is_super_user boolean;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select coalesce("SuperUser", false) into v_is_super_user
  from public."StaffUsers"
  where "Username" = p_admin_username;

  return query
    with candidates as (
      select o."OrderID"::text as id, 'online'::text as src,
             coalesce(nullif(trim(o."WalkinCustomerName"), ''), o."CustomerName")::text as cust,
             o."Status"::text as st, o."ShippingAddress"::text as addr,
             coalesce(nullif(trim(o."WalkinCustomerPhone"), ''), o."ShippingPhone")::text as phone,
             o."MoneyToCollect" as mtc, o."Balance" as bal, o."EstimatedDeliveryDate" as edd,
             (coalesce(o."ReceivedAtShop", false)
              or lower(trim(coalesce(o."CustomerName", ''))) = 'pos walkin orders'
              or lower(trim(coalesce(o."ShippingAddress", ''))) = 'walkin') as walk_in,
             o."Last_Updated_At" as sort_at
      from public."OnlineOrders" o
      where (
          lower(o."Status") in ('confirmed', 'printed', 'to ship', 'shipped')
          or (coalesce(v_is_super_user, false) and lower(o."Status") in ('canceled', 'cancelled'))
        )
        and not exists (select 1 from public."DeliveryStops" s where s."OrderID" = o."OrderID")
        -- its advance order (if any) is already scheduled under the advance number
        and not exists (
          select 1 from public."AdvanceOrders" a
          join public."DeliveryStops" s on s."AdvanceTransactionNo" = a."TransactionNo"
          where nullif(trim(a."OnlineOrderID"), '') = o."OrderID")
        and (v_search is null
             or o."OrderID" ilike '%' || v_search || '%'
             or o."CustomerName" ilike '%' || v_search || '%'
             or o."WalkinCustomerName" ilike '%' || v_search || '%')

      union all

      select a."TransactionNo"::text, 'advance',
             a."CustomerName"::text,
             ('Advance' || coalesce(' - ' || public._advance_order_prod_status(p), ''))::text,
             null::text, null::text,
             a."Balance", a."Balance", null::date,
             false,
             greatest(a."DatePaid",
                      (a."Date" + coalesce(public._advance_order_time(a."Time"), time '00:00')) at time zone 'Asia/Manila')
      from public."AdvanceOrders" a
      left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
      where not exists (select 1 from public."DeliveryStops" s where s."AdvanceTransactionNo" = a."TransactionNo")
        -- its linked online order is already scheduled
        and not exists (select 1 from public."DeliveryStops" s
                        where s."OrderID" = nullif(trim(a."OnlineOrderID"), ''))
        and (v_search is null
             or a."TransactionNo" ilike '%' || v_search || '%'
             or a."ReceiptNo" ilike '%' || v_search || '%'
             or a."CustomerName" ilike '%' || v_search || '%'
             or a."OnlineOrderID" ilike '%' || v_search || '%')
    ),
    keyed as (
      select c.*,
             -- order numbers sort as numbers (9 before 10), anything non-numeric after them
             case when v_sort = 'order_id' and c.id ~ '^\d+$' then c.id::numeric end as num_key,
             case v_sort
               when 'order_id' then lower(c.id)
               when 'customer_name' then lower(nullif(trim(c.cust), ''))
               when 'status' then lower(nullif(trim(c.st), ''))
               when 'shipping_address' then lower(nullif(trim(c.addr), ''))
               when 'type' then case when c.src = 'advance' then 'advance' when c.walk_in then 'walk-in' else 'online' end
             end as text_key
      from candidates c
    )
    select k.id, k.src, k.cust, k.st, k.addr, k.phone, k.mtc, k.bal, k.edd, k.walk_in,
           count(*) over()
    from keyed k
    order by case when not v_desc then k.num_key end asc nulls last,
             case when v_desc then k.num_key end desc nulls last,
             case when not v_desc then k.text_key end asc nulls last,
             case when v_desc then k.text_key end desc nulls last,
             k.sort_at desc nulls last, k.id desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_deliverable_online_orders(text, text, text, int, int, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 3. Create stop: p_source picks which table p_order_id belongs to.

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'admin_create_delivery_stop'
  loop
    execute format('drop function %s', r.signature);
  end loop;
end;
$$;

create or replace function public.admin_create_delivery_stop(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_delivery_date date,
  p_truck_id uuid default null,
  p_notes text default null,
  p_source text default 'online'
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_truck_id uuid;
  v_next_sequence int;
  v_id uuid;
  v_route_name text;
  v_is_advance boolean := lower(coalesce(p_source, 'online')) = 'advance';
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_order_id is null or trim(p_order_id) = '' or p_delivery_date is null then
    raise exception 'Order ID and delivery date are required.';
  end if;

  if extract(dow from p_delivery_date) = 1 then
    raise exception 'Mondays are not available for delivery.';
  end if;

  if v_is_advance and not exists (select 1 from public."AdvanceOrders" where "TransactionNo" = p_order_id) then
    raise exception 'Advance order % not found.', p_order_id;
  end if;

  select "RouteName" into v_route_name
  from public."DeliveryRouteSchedule"
  where "DayOfWeek" = extract(dow from p_delivery_date);

  v_truck_id := p_truck_id;
  if v_truck_id is null then
    select "TruckID" into v_truck_id from public."DeliveryTrucks" where "IsActive" is true order by "CreatedAtUtc" limit 1;
  end if;

  if v_truck_id is null then
    raise exception 'No active delivery truck is configured.';
  end if;

  select coalesce(max("StopSequence") + 1, 0) into v_next_sequence
  from public."DeliveryStops"
  where "DeliveryDate" = p_delivery_date and "TruckID" = v_truck_id;

  begin
    insert into public."DeliveryStops" ("OrderID", "AdvanceTransactionNo", "TruckID", "DeliveryDate", "StopSequence", "Notes", "CreatedBy", "RouteName")
    values (case when v_is_advance then null else p_order_id end,
            case when v_is_advance then p_order_id end,
            v_truck_id, p_delivery_date, v_next_sequence, p_notes, p_admin_username, v_route_name)
    returning "StopID" into v_id;
  exception when unique_violation then
    raise exception 'This order is already scheduled for that date.';
  end;

  if not v_is_advance then
    update public."OnlineOrders" set "ForDelivery" = true where "OrderID" = p_order_id;
  end if;

  return v_id;
end;
$$;

grant execute on function public.admin_create_delivery_stop(text, text, text, date, uuid, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 4. Stops list: advance stops + walk-in name/phone. Adds a trailing "source" column.

drop function if exists public.admin_list_delivery_stops(text, text, date, date);

create or replace function public.admin_list_delivery_stops(p_admin_username text, p_admin_password text, p_start_date date, p_end_date date)
returns table(
  stop_id uuid,
  delivery_date date,
  truck_id uuid,
  truck_name text,
  stop_sequence int,
  order_id text,
  customer_name text,
  status text,
  shipping_address text,
  money_to_collect numeric,
  balance numeric,
  notes text,
  latitude numeric,
  longitude numeric,
  geocode_status text,
  geocoded_address text,
  route_name text,
  created_by text,
  note_print text,
  contact_number text,
  is_manual_address boolean,
  source text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select s."StopID", s."DeliveryDate", s."TruckID", t."TruckName"::text, s."StopSequence",
           coalesce(o."OrderID", 'ADV-' || a."TransactionNo")::text,
           coalesce(nullif(trim(s."ManualCustomerName"), ''), nullif(trim(o."WalkinCustomerName"), ''),
                    o."CustomerName", a."CustomerName")::text,
           case when a."TransactionNo" is not null
                then 'Advance' || coalesce(' - ' || public._advance_order_prod_status(p), '')
                else o."Status" end::text,
           coalesce(nullif(trim(s."ManualAddress"), ''), o."ShippingAddress")::text,
           coalesce(o."MoneyToCollect", a."Balance"), coalesce(o."Balance", a."Balance"), s."Notes"::text,
           s."Latitude", s."Longitude", s."GeocodeStatus"::text, s."GeocodedAddress"::text,
           s."RouteName"::text, s."CreatedBy"::text,
           coalesce(
             nullif(trim(s."ManualNotePrint"), ''),
             nullif(trim(o."NotePrint"::text), ''),
             (select string_agg(nullif(trim(l."Note"::text), ''), '; ' order by l."LineID")
                from public."OnlineOrderLines" l
                where l."OrderID" = o."OrderID" and nullif(trim(l."Note"::text), '') is not null),
             nullif(trim(a."Order_Description"::text), '')
           ) as note_print,
           coalesce(nullif(trim(s."ManualContactNumber"), ''), nullif(trim(o."WalkinCustomerPhone"), ''))::text as contact_number,
           (nullif(trim(s."ManualAddress"), '') is not null) as is_manual_address,
           case when a."TransactionNo" is not null then 'advance' else 'online' end::text
    from public."DeliveryStops" s
    left join public."OnlineOrders" o on o."OrderID" = s."OrderID"
    left join public."AdvanceOrders" a on a."TransactionNo" = s."AdvanceTransactionNo"
    left join public."AdvanceOrderProduction" p on p."TransactionNo" = s."AdvanceTransactionNo"
    join public."DeliveryTrucks" t on t."TruckID" = s."TruckID"
    where s."DeliveryDate" >= p_start_date and s."DeliveryDate" < p_end_date
      and (o."OrderID" is not null or a."TransactionNo" is not null)
    order by s."DeliveryDate", s."StopSequence";
end;
$$;

grant execute on function public.admin_list_delivery_stops(text, text, date, date) to anon;

-- ---------------------------------------------------------------------------
-- 5. Receipt / invoice / job order / driver detail: advance stops read AdvanceOrders + AdvanceOrderLines.
--    Adds a trailing "source" column (the driver view skips online-order attachments for advance stops).

drop function if exists public.admin_get_delivery_receipt(text, text, uuid);

create or replace function public.admin_get_delivery_receipt(
  p_admin_username text,
  p_admin_password text,
  p_stop_id uuid
)
returns table(
  order_id text,
  order_date date,
  customer_name text,
  shipping_address text,
  shipping_phone text,
  delivery_fee numeric,
  note_print text,
  stop_notes text,
  confirmed_by text,
  warehouse_name text,
  warehouse_address text,
  money_to_collect numeric,
  amount_paid numeric,
  discount numeric,
  balance numeric,
  line_no int,
  line_id text,
  line_description text,
  line_quantity numeric,
  line_amount numeric,
  line_note text,
  source text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_id text;
  v_advance_no text;
  v_geocoded_address text;
  v_manual_address text;
  v_manual_customer_name text;
  v_manual_contact_number text;
  v_manual_note_print text;
  v_stop_notes text;
  v_order_date date;
  v_customer_name text;
  v_shipping_address text;
  v_shipping_phone text;
  v_delivery_fee numeric;
  v_note_print text;
  v_confirmed_by text;
  v_warehouse_name text;
  v_warehouse_address text;
  v_money_to_collect numeric;
  v_amount_paid numeric;
  v_discount numeric;
  v_balance numeric;
  v_line record;
  v_line_no int := 0;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select s."OrderID", s."AdvanceTransactionNo", s."GeocodedAddress", s."ManualAddress", s."ManualCustomerName", s."ManualContactNumber", s."ManualNotePrint", s."Notes"::text
    into v_order_id, v_advance_no, v_geocoded_address, v_manual_address, v_manual_customer_name, v_manual_contact_number, v_manual_note_print, v_stop_notes
  from public."DeliveryStops" s
  where s."StopID" = p_stop_id;

  if v_order_id is null and v_advance_no is null then
    raise exception 'Delivery stop not found.';
  end if;

  if v_advance_no is not null then
    select a."Date", a."CustomerName"::text, a."Order_Description"::text, a."UserID"::text,
           coalesce(w."Name", a."Warehouse")::text, w."Address"::text,
           a."Balance", a."Downpayment", a."Discount", a."Balance"
      into v_order_date, v_customer_name, v_note_print, v_confirmed_by,
           v_warehouse_name, v_warehouse_address,
           v_money_to_collect, v_amount_paid, v_discount, v_balance
    from public."AdvanceOrders" a
    left join public."Warehouses" w on lower(trim(w."Name")) = lower(trim(a."Warehouse"))
    where a."TransactionNo" = v_advance_no;
  else
    select o."Date", coalesce(nullif(trim(o."WalkinCustomerName"), ''), o."CustomerName")::text, o."ShippingAddress"::text,
           coalesce(nullif(trim(o."WalkinCustomerPhone"), ''), o."ShippingPhone")::text, o."DeliveryFee", o."NotePrint"::text,
           o."ConfirmedBy"::text, w."Name"::text, w."Address"::text,
           o."MoneyToCollect", o."AmountPaid", o."Discount", o."Balance"
      into v_order_date, v_customer_name, v_shipping_address, v_shipping_phone, v_delivery_fee, v_note_print,
           v_confirmed_by, v_warehouse_name, v_warehouse_address,
           v_money_to_collect, v_amount_paid, v_discount, v_balance
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    where o."OrderID" = v_order_id;
  end if;

  v_customer_name := coalesce(nullif(trim(v_manual_customer_name), ''), v_customer_name);
  v_shipping_phone := coalesce(nullif(trim(v_manual_contact_number), ''), v_shipping_phone);
  v_note_print := coalesce(nullif(trim(v_manual_note_print), ''), v_note_print);
  v_shipping_address := coalesce(nullif(trim(v_manual_address), ''), v_shipping_address);

  v_shipping_address := case
    when v_shipping_address is null or trim(v_shipping_address) = '' or lower(trim(v_shipping_address)) = 'walkin'
      then v_geocoded_address
    else v_shipping_address
  end;

  order_id := coalesce(v_order_id, 'ADV-' || v_advance_no);
  order_date := v_order_date;
  customer_name := v_customer_name;
  shipping_address := v_shipping_address;
  shipping_phone := v_shipping_phone;
  delivery_fee := v_delivery_fee;
  note_print := v_note_print;
  stop_notes := v_stop_notes;
  confirmed_by := v_confirmed_by;
  warehouse_name := v_warehouse_name;
  warehouse_address := v_warehouse_address;
  money_to_collect := v_money_to_collect;
  amount_paid := v_amount_paid;
  discount := v_discount;
  balance := v_balance;
  source := case when v_advance_no is not null then 'advance' else 'online' end;

  for v_line in
    select l."LineID"::text as line_id, l."Description"::text as description, l."Quantity" as quantity,
           coalesce(l."GrossAmount", l."NetAmount", l."Price" * l."Quantity") as amount,
           nullif(trim(l."Note"::text), '') as note,
           l."LineID"::text as sort_key
    from public."OnlineOrderLines" l
    where v_order_id is not null and l."OrderID" = v_order_id
    union all
    select al."LineNo"::text, al."Description"::text, al."Quantity",
           coalesce(al."GrossAmount", al."NetAmount", al."Price" * al."Quantity"),
           null::text,
           lpad(al."LineNo"::text, 12, '0')
    from public."AdvanceOrderLines" al
    where v_advance_no is not null and al."TransactionNo" = v_advance_no
    order by sort_key
  loop
    v_line_no := v_line_no + 1;
    line_no := v_line_no;
    line_id := v_line.line_id;
    line_description := v_line.description;
    line_quantity := v_line.quantity;
    line_amount := v_line.amount;
    line_note := v_line.note;
    return next;
  end loop;

  if v_line_no = 0 then
    line_no := null;
    line_id := null;
    line_description := null;
    line_quantity := null;
    line_amount := null;
    line_note := null;
    return next;
  end if;
end;
$$;

grant execute on function public.admin_get_delivery_receipt(text, text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- 6. Delivery-team push: label advance stops "Advance Order <no>".

create or replace function public._notify_delivery_stop_changed()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row public."DeliveryStops" := case when TG_OP = 'DELETE' then OLD else NEW end;
  v_customer text;
  v_label text;
  v_changes text[] := '{}';
  v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  if v_row."AdvanceTransactionNo" is not null then
    select coalesce(nullif(trim(v_row."ManualCustomerName"), ''), a."CustomerName")
      into v_customer
    from public."AdvanceOrders" a where a."TransactionNo" = v_row."AdvanceTransactionNo";
    v_label := 'Advance Order ' || v_row."AdvanceTransactionNo" || coalesce(' - ' || nullif(trim(v_customer), ''), '');
  else
    select coalesce(nullif(trim(v_row."ManualCustomerName"), ''), nullif(trim(o."WalkinCustomerName"), ''), o."CustomerName")
      into v_customer
    from public."OnlineOrders" o where o."OrderID" = v_row."OrderID";
    v_label := 'Order ' || coalesce(v_row."OrderID", '-') || coalesce(' - ' || nullif(trim(v_customer), ''), '');
  end if;

  if TG_OP = 'INSERT' then
    perform public._notify_delivery_team('Delivery stop added',
      to_char(NEW."DeliveryDate", 'Dy Mon DD') || ': ' || v_label || coalesce(' (' || nullif(trim(NEW."RouteName"), '') || ')', ''),
      NEW."DeliveryDate");

  elsif TG_OP = 'DELETE' then
    perform public._notify_delivery_team('Delivery stop removed',
      to_char(OLD."DeliveryDate", 'Dy Mon DD') || ': ' || v_label,
      OLD."DeliveryDate");

  elsif NEW."DeliveryDate" is distinct from OLD."DeliveryDate" then
    if greatest(NEW."DeliveryDate", OLD."DeliveryDate") >= v_today then
      perform public._notify_delivery_team('Delivery stop moved',
        v_label || ': ' || to_char(OLD."DeliveryDate", 'Dy Mon DD') || ' -> ' || to_char(NEW."DeliveryDate", 'Dy Mon DD'),
        case when NEW."DeliveryDate" >= v_today then NEW."DeliveryDate" else OLD."DeliveryDate" end);
    end if;

  else
    if NEW."ManualAddress" is distinct from OLD."ManualAddress" then v_changes := array_append(v_changes, 'address'); end if;
    if NEW."Notes" is distinct from OLD."Notes" then v_changes := array_append(v_changes, 'notes'); end if;
    if NEW."ManualNotePrint" is distinct from OLD."ManualNotePrint" then v_changes := array_append(v_changes, 'print note'); end if;
    if NEW."ManualCustomerName" is distinct from OLD."ManualCustomerName"
       or NEW."ManualContactNumber" is distinct from OLD."ManualContactNumber" then v_changes := array_append(v_changes, 'customer details'); end if;
    if NEW."StopSequence" is distinct from OLD."StopSequence" then v_changes := array_append(v_changes, 'stop order'); end if;
    if NEW."TruckID" is distinct from OLD."TruckID" then v_changes := array_append(v_changes, 'truck'); end if;

    if array_length(v_changes, 1) is not null then
      perform public._notify_delivery_team('Delivery stop updated',
        to_char(NEW."DeliveryDate", 'Dy Mon DD') || ': ' || v_label || ' - ' || array_to_string(v_changes, ', ') || ' changed',
        NEW."DeliveryDate");
    end if;
  end if;

  return null;
end;
$$;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'function' as section, p.proname::text as item,
       pg_get_function_identity_arguments(p.oid) as detail
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('admin_list_deliverable_online_orders', 'admin_create_delivery_stop',
                    'admin_list_delivery_stops', 'admin_get_delivery_receipt', '_notify_delivery_stop_changed')
union all
select 'column', 'DeliveryStops.AdvanceTransactionNo',
       case when exists (select 1 from information_schema.columns
                         where table_schema = 'public' and table_name = 'DeliveryStops' and column_name = 'AdvanceTransactionNo')
            then 'ok' else 'MISSING' end
union all
-- Advance order 10295 should now be assignable (not on the calendar yet).
select 'advance 10295', a."TransactionNo"::text,
       coalesce(a."CustomerName", '') || ' | receipt ' || coalesce(a."ReceiptNo", '-') ||
       case when exists (select 1 from public."DeliveryStops" s where s."AdvanceTransactionNo" = a."TransactionNo")
            then ' | already scheduled' else ' | assignable' end
from public."AdvanceOrders" a
where a."TransactionNo" ilike '%10295%' or a."ReceiptNo" ilike '%10295%'
order by 1, 2;
