-- Delivery calendar: assign Automated Orders ("AO-00039") - per "can you show the advance order to
-- the delivery calendar too?" (searching AO-00039 returned "No deliverable orders found") and "even
-- though we did not sync to pancake yet the order should be assigned still".
--
-- An AO- number is a bot / GMA Conversations / order-wizard order (public."AutomatedOrders"), not an
-- Advance Order. Bot and GMA orders no longer go to Pancake (supabase_bot_orders_portal_confirm.sql):
-- they sit as a draft until staff click Confirm Order, which creates the OnlineOrders row with
-- OrderID = the AO number and sets AutomatedOrders."PancakeReceiptNo" = the AO number too. (Older
-- orders that were pushed to Pancake link the same way, but to Pancake's own number.)
--
--   CONFIRMED AO  -> already an online order ("AO-00039", or "112345 · AO-00039" for an older
--                    Pancake one - new trailing automated_order_no column), findable by AO number.
--   DRAFT AO      -> listed on its own (source 'automated', Order ID "AO-00039", status
--                    "New - not confirmed yet") with the order's address / phone / lines, and can
--                    be assigned: a stop now points at exactly ONE of
--                      "OrderID"              -> OnlineOrders
--                      "AdvanceTransactionNo" -> AdvanceOrders
--                      "AutomatedOrderNo"     -> AutomatedOrders (new)
--   CONFIRMED LATER -> a trigger moves the stop onto the online order (OrderID set,
--                    AutomatedOrderNo cleared) as soon as both the OnlineOrders row and
--                    PancakeReceiptNo exist - so from then on it's a normal online stop (Mark Done ->
--                    Delivered, chatbot delivery status, attachments) with nothing else to change.
--
-- Re-creates (latest versions): admin_list_deliverable_online_orders + admin_create_delivery_stop
-- (supabase_delivery_advance_and_walkin_orders.sql), admin_list_delivery_stops + admin_get_delivery_receipt
-- + _notify_delivery_stop_changed (supabase_delivery_stop_manual_fee.sql).
-- Run AFTER supabase_delivery_stop_manual_fee.sql. Safe to re-run.
-- Needs js/delivery.js ?v=aosearch2 (reload the Delivery page after running).

-- ---------------------------------------------------------------------------
-- 1. DeliveryStops: an automated order can be the stop's order.

set lock_timeout = '10s';

alter table public."DeliveryStops" add column if not exists "AutomatedOrderNo" varchar(50)
  references public."AutomatedOrders"("OrderNo") on delete cascade;

alter table public."DeliveryStops" drop constraint if exists "CK_DeliveryStops_OneOrder";
alter table public."DeliveryStops" add constraint "CK_DeliveryStops_OneOrder"
  check (num_nonnulls("OrderID", "AdvanceTransactionNo", "AutomatedOrderNo") = 1);

reset lock_timeout;

create unique index if not exists "UQ_DeliveryStops_Automated_Date"
  on public."DeliveryStops" ("AutomatedOrderNo", "DeliveryDate")
  where "AutomatedOrderNo" is not null;

-- Amount to collect for a not-yet-synced AO: its lines (EstimatedTotal if it has none).
create or replace function public._automated_order_total(p_order_no text)
returns numeric
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(
    (select sum(l."Price" * l."Quantity") from public."AutomatedOrderLines" l where l."OrderNo" = p_order_no),
    (select a."EstimatedTotal" from public."AutomatedOrders" a where a."OrderNo" = p_order_no));
$$;

-- ---------------------------------------------------------------------------
-- Status suffix for an AO with no online order yet: a draft waiting for Confirm Order, or (older
-- orders only) one pushed to Pancake whose copy hasn't been pulled down yet.
create or replace function public._automated_order_pending_label(p_sync_status text)
returns text
language sql
immutable
as $$
  select case when p_sync_status in ('Not Pushed', 'Portal') or p_sync_status is null
              then ' - not confirmed yet' else ' - not in Online Orders yet' end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Move an AO stop onto its online order once the AO is confirmed (both rows must exist - the
--    OnlineOrders row and PancakeReceiptNo can land in either order, so both tables trigger it).

create or replace function public._delivery_stops_adopt_synced_automated(p_order_no text, p_online_order_id text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if p_order_no is null or p_online_order_id is null then return; end if;

  update public."DeliveryStops" s
     set "OrderID" = p_online_order_id, "AutomatedOrderNo" = null
   where s."AutomatedOrderNo" = p_order_no
     and exists (select 1 from public."OnlineOrders" o where o."OrderID" = p_online_order_id)
     -- never collide with a stop the online order already has (UQ_DeliveryStops_Order_Date)
     and not exists (select 1 from public."DeliveryStops" x where x."OrderID" = p_online_order_id);

  if found then
    update public."OnlineOrders" set "ForDelivery" = true where "OrderID" = p_online_order_id;
  end if;
end;
$$;

create or replace function public._online_orders_adopt_automated_stop()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_no text;
begin
  for v_order_no in
    select a."OrderNo" from public."AutomatedOrders" a where a."PancakeReceiptNo" = NEW."OrderID"
  loop
    perform public._delivery_stops_adopt_synced_automated(v_order_no, NEW."OrderID");
  end loop;
  return null;
end;
$$;

drop trigger if exists "TR_OnlineOrders_AdoptAutomatedStop" on public."OnlineOrders";
create trigger "TR_OnlineOrders_AdoptAutomatedStop"
  after insert on public."OnlineOrders"
  for each row execute function public._online_orders_adopt_automated_stop();

create or replace function public._automated_orders_adopt_stop()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._delivery_stops_adopt_synced_automated(NEW."OrderNo", nullif(trim(NEW."PancakeReceiptNo"), ''));
  return null;
end;
$$;

drop trigger if exists "TR_AutomatedOrders_AdoptStop" on public."AutomatedOrders";
create trigger "TR_AutomatedOrders_AdoptStop"
  after update of "PancakeReceiptNo" on public."AutomatedOrders"
  for each row when (NEW."PancakeReceiptNo" is not null)
  execute function public._automated_orders_adopt_stop();

-- ---------------------------------------------------------------------------
-- 3. Assign list: online (incl. walk-in) + advance + not-yet-synced automated orders.

drop function if exists public.admin_list_deliverable_online_orders(text, text, text, int, int, text, text);

create or replace function public.admin_list_deliverable_online_orders(p_admin_username text, p_admin_password text, p_search text default null, p_page int default 1, p_page_size int default 50,
  p_sort_column text default null, p_sort_dir text default 'asc')
returns table(
  order_id text,                 -- OnlineOrders.OrderID / AdvanceOrders.TransactionNo / AutomatedOrders.OrderNo, by source
  source text,                   -- 'online' | 'advance' | 'automated'
  customer_name text,
  status text,
  shipping_address text,
  contact_number text,
  money_to_collect numeric,
  balance numeric,
  estimated_delivery_date date,
  is_walk_in boolean,
  total_count bigint,
  automated_order_no text        -- AutomatedOrders.OrderNo ("AO-00039") behind the order, if any
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
             o."Last_Updated_At" as sort_at,
             (select ao."OrderNo"::text from public."AutomatedOrders" ao
              where ao."PancakeReceiptNo" = o."OrderID" order by ao."OrderNo" limit 1) as ao_no
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
        -- its automated order is already scheduled under the AO number
        and not exists (
          select 1 from public."AutomatedOrders" ao
          join public."DeliveryStops" s on s."AutomatedOrderNo" = ao."OrderNo"
          where ao."PancakeReceiptNo" = o."OrderID")
        and (v_search is null
             or o."OrderID" ilike '%' || v_search || '%'
             or o."CustomerName" ilike '%' || v_search || '%'
             or o."WalkinCustomerName" ilike '%' || v_search || '%'
             or exists (select 1 from public."AutomatedOrders" ao
                        where ao."PancakeReceiptNo" = o."OrderID"
                          and ao."OrderNo" ilike '%' || v_search || '%'))

      union all

      select a."TransactionNo"::text, 'advance',
             a."CustomerName"::text,
             ('Advance' || coalesce(' - ' || public._advance_order_prod_status(p), ''))::text,
             null::text, null::text,
             a."Balance", a."Balance", null::date,
             false,
             greatest(a."DatePaid",
                      (a."Date" + coalesce(public._advance_order_time(a."Time"), time '00:00')) at time zone 'Asia/Manila'),
             null::text
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

      union all

      -- Automated orders with no online order yet (draft awaiting Confirm Order).
      select ao."OrderNo"::text, 'automated',
             ao."CustomerName"::text,
             (ao."Status" || public._automated_order_pending_label(ao."PancakeSyncStatus"))::text,
             ao."DeliveryAddress"::text, ao."CustomerPhone"::text,
             public._automated_order_total(ao."OrderNo"), public._automated_order_total(ao."OrderNo"),
             null::date,
             false,
             ao."UpdatedAtUtc",
             ao."OrderNo"::text
      from public."AutomatedOrders" ao
      where not exists (select 1 from public."OnlineOrders" o
                        where o."OrderID" = nullif(trim(ao."PancakeReceiptNo"), ''))
        and (lower(ao."Status") not in ('cancelled', 'canceled') or coalesce(v_is_super_user, false))
        and not exists (select 1 from public."DeliveryStops" s where s."AutomatedOrderNo" = ao."OrderNo")
        and (v_search is null
             or ao."OrderNo" ilike '%' || v_search || '%'
             or ao."CustomerName" ilike '%' || v_search || '%'
             or ao."CustomerPhone" ilike '%' || v_search || '%')
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
               when 'type' then case when c.src = 'advance' then 'advance' when c.src = 'automated' then 'order form'
                                     when c.walk_in then 'walk-in' else 'online' end
             end as text_key
      from candidates c
    )
    select k.id, k.src, k.cust, k.st, k.addr, k.phone, k.mtc, k.bal, k.edd, k.walk_in,
           count(*) over(), k.ao_no
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
-- 4. Create stop: p_source 'automated' -> AutomatedOrderNo. If the AO's online order already exists,
--    the stop is made on the online order instead.

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
  v_source text := lower(coalesce(p_source, 'online'));
  v_order_id text := p_order_id;
  v_synced_id text;
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

  if v_source = 'advance' and not exists (select 1 from public."AdvanceOrders" where "TransactionNo" = p_order_id) then
    raise exception 'Advance order % not found.', p_order_id;
  end if;

  if v_source = 'automated' then
    if not exists (select 1 from public."AutomatedOrders" where "OrderNo" = p_order_id) then
      raise exception 'Order % not found.', p_order_id;
    end if;

    select o."OrderID" into v_synced_id
    from public."AutomatedOrders" ao
    join public."OnlineOrders" o on o."OrderID" = nullif(trim(ao."PancakeReceiptNo"), '')
    where ao."OrderNo" = p_order_id;

    if v_synced_id is not null then
      v_source := 'online';
      v_order_id := v_synced_id;
    end if;
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
    insert into public."DeliveryStops" ("OrderID", "AdvanceTransactionNo", "AutomatedOrderNo", "TruckID", "DeliveryDate", "StopSequence", "Notes", "CreatedBy", "RouteName")
    values (case when v_source = 'online' then v_order_id end,
            case when v_source = 'advance' then v_order_id end,
            case when v_source = 'automated' then v_order_id end,
            v_truck_id, p_delivery_date, v_next_sequence, p_notes, p_admin_username, v_route_name)
    returning "StopID" into v_id;
  exception when unique_violation then
    raise exception 'This order is already scheduled for that date.';
  end;

  if v_source = 'online' then
    update public."OnlineOrders" set "ForDelivery" = true where "OrderID" = v_order_id;
  end if;

  return v_id;
end;
$$;

grant execute on function public.admin_create_delivery_stop(text, text, text, date, uuid, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 5. Stops list: + automated stops (source 'automated', order_id "AO-00039").

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
  source text,
  delivery_fee numeric,
  is_manual_delivery_fee boolean
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
           coalesce(o."OrderID", 'ADV-' || a."TransactionNo", ao."OrderNo")::text,
           coalesce(nullif(trim(s."ManualCustomerName"), ''), nullif(trim(o."WalkinCustomerName"), ''),
                    o."CustomerName", a."CustomerName", ao."CustomerName")::text,
           case when a."TransactionNo" is not null
                  then 'Advance' || coalesce(' - ' || public._advance_order_prod_status(p), '')
                when ao."OrderNo" is not null
                  then ao."Status" || public._automated_order_pending_label(ao."PancakeSyncStatus")
                else o."Status" end::text,
           coalesce(nullif(trim(s."ManualAddress"), ''), o."ShippingAddress", ao."DeliveryAddress")::text,
           -- + (manual fee - the order's own fee) once a manual fee is set.
           coalesce(o."MoneyToCollect", a."Balance", public._automated_order_total(ao."OrderNo"))
             + coalesce(s."ManualDeliveryFee" - coalesce(o."DeliveryFee", 0), 0),
           coalesce(o."Balance", a."Balance", public._automated_order_total(ao."OrderNo"))
             + coalesce(s."ManualDeliveryFee" - coalesce(o."DeliveryFee", 0), 0),
           s."Notes"::text,
           s."Latitude", s."Longitude", s."GeocodeStatus"::text, s."GeocodedAddress"::text,
           s."RouteName"::text, s."CreatedBy"::text,
           coalesce(
             nullif(trim(s."ManualNotePrint"), ''),
             nullif(trim(o."NotePrint"::text), ''),
             (select string_agg(nullif(trim(l."Note"::text), ''), '; ' order by l."LineID")
                from public."OnlineOrderLines" l
                where l."OrderID" = o."OrderID" and nullif(trim(l."Note"::text), '') is not null),
             nullif(trim(a."Order_Description"::text), ''),
             nullif(trim(ao."Notes"::text), '')
           ) as note_print,
           coalesce(nullif(trim(s."ManualContactNumber"), ''), nullif(trim(o."WalkinCustomerPhone"), ''),
                    nullif(trim(ao."CustomerPhone"), ''))::text as contact_number,
           (nullif(trim(s."ManualAddress"), '') is not null) as is_manual_address,
           case when a."TransactionNo" is not null then 'advance'
                when ao."OrderNo" is not null then 'automated'
                else 'online' end::text,
           coalesce(s."ManualDeliveryFee", o."DeliveryFee"),
           s."ManualDeliveryFee" is not null
    from public."DeliveryStops" s
    left join public."OnlineOrders" o on o."OrderID" = s."OrderID"
    left join public."AdvanceOrders" a on a."TransactionNo" = s."AdvanceTransactionNo"
    left join public."AdvanceOrderProduction" p on p."TransactionNo" = s."AdvanceTransactionNo"
    left join public."AutomatedOrders" ao on ao."OrderNo" = s."AutomatedOrderNo"
    join public."DeliveryTrucks" t on t."TruckID" = s."TruckID"
    where s."DeliveryDate" >= p_start_date and s."DeliveryDate" < p_end_date
      and (o."OrderID" is not null or a."TransactionNo" is not null or ao."OrderNo" is not null)
    order by s."DeliveryDate", s."StopSequence";
end;
$$;

grant execute on function public.admin_list_delivery_stops(text, text, date, date) to anon;

-- ---------------------------------------------------------------------------
-- 6. Receipt / invoice / job order / driver detail: automated stops read AutomatedOrders + lines.

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
  v_automated_no text;
  v_geocoded_address text;
  v_manual_address text;
  v_manual_customer_name text;
  v_manual_contact_number text;
  v_manual_note_print text;
  v_manual_fee numeric;
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

  select s."OrderID", s."AdvanceTransactionNo", s."AutomatedOrderNo", s."GeocodedAddress", s."ManualAddress", s."ManualCustomerName", s."ManualContactNumber", s."ManualNotePrint", s."Notes"::text, s."ManualDeliveryFee"
    into v_order_id, v_advance_no, v_automated_no, v_geocoded_address, v_manual_address, v_manual_customer_name, v_manual_contact_number, v_manual_note_print, v_stop_notes, v_manual_fee
  from public."DeliveryStops" s
  where s."StopID" = p_stop_id;

  if v_order_id is null and v_advance_no is null and v_automated_no is null then
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
  elsif v_automated_no is not null then
    select (ao."CreatedAtUtc" at time zone 'Asia/Manila')::date, ao."CustomerName"::text, ao."DeliveryAddress"::text,
           ao."CustomerPhone"::text, ao."Notes"::text, ao."UpdatedBy"::text,
           coalesce(w."Name", ao."Location")::text, w."Address"::text,
           public._automated_order_total(ao."OrderNo"), 0, 0, public._automated_order_total(ao."OrderNo")
      into v_order_date, v_customer_name, v_shipping_address, v_shipping_phone, v_note_print, v_confirmed_by,
           v_warehouse_name, v_warehouse_address,
           v_money_to_collect, v_amount_paid, v_discount, v_balance
    from public."AutomatedOrders" ao
    left join lateral (
      select w0."Name", w0."Address" from public."Warehouses" w0
      where nullif(trim(ao."Location"), '') is not null and w0."Name" ilike '%' || trim(ao."Location") || '%'
      order by w0."Name" limit 1
    ) w on true
    where ao."OrderNo" = v_automated_no;
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

  -- Manual delivery fee: replaces the order's fee, and Total / Balance move by the difference.
  if v_manual_fee is not null then
    v_money_to_collect := coalesce(v_money_to_collect, 0) + v_manual_fee - coalesce(v_delivery_fee, 0);
    v_balance := coalesce(v_balance, 0) + v_manual_fee - coalesce(v_delivery_fee, 0);
    v_delivery_fee := v_manual_fee;
  end if;

  v_shipping_address := case
    when v_shipping_address is null or trim(v_shipping_address) = '' or lower(trim(v_shipping_address)) = 'walkin'
      then v_geocoded_address
    else v_shipping_address
  end;

  order_id := coalesce(v_order_id, 'ADV-' || v_advance_no, v_automated_no);
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
  source := case when v_advance_no is not null then 'advance'
                 when v_automated_no is not null then 'automated'
                 else 'online' end;

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
    union all
    select aol."EntryNo"::text, aol."ItemName"::text, aol."Quantity"::numeric,
           aol."Price" * aol."Quantity",
           nullif(trim(aol."Notes"::text), ''),
           lpad(aol."EntryNo"::text, 12, '0')
    from public."AutomatedOrderLines" aol
    where v_automated_no is not null and aol."OrderNo" = v_automated_no
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
-- 7. Delivery-team push: label automated stops "Order AO-00039". Moving a stop onto its synced
--    online order changes none of the tracked fields, so it sends no push.

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
  elsif v_row."AutomatedOrderNo" is not null then
    select coalesce(nullif(trim(v_row."ManualCustomerName"), ''), ao."CustomerName")
      into v_customer
    from public."AutomatedOrders" ao where ao."OrderNo" = v_row."AutomatedOrderNo";
    v_label := 'Order ' || v_row."AutomatedOrderNo" || coalesce(' - ' || nullif(trim(v_customer), ''), '');
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
    if NEW."ManualDeliveryFee" is distinct from OLD."ManualDeliveryFee" then v_changes := array_append(v_changes, 'delivery fee'); end if;
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

-- Verification - one result: functions/column in place, and where AO-00039 stands.
select 'function' as section, p.proname::text as item, pg_get_function_identity_arguments(p.oid) as detail
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('admin_list_deliverable_online_orders', 'admin_create_delivery_stop', 'admin_list_delivery_stops',
                    'admin_get_delivery_receipt', '_delivery_stops_adopt_synced_automated', '_automated_order_total')
union all
select 'column', 'DeliveryStops.AutomatedOrderNo',
       case when exists (select 1 from information_schema.columns
                         where table_schema = 'public' and table_name = 'DeliveryStops' and column_name = 'AutomatedOrderNo')
            then 'ok' else 'MISSING' end
union all
select 'AO-00039', ao."OrderNo"::text,
       'status: ' || coalesce(ao."Status", '-') ||
       ' | sync status: ' || coalesce(ao."PancakeSyncStatus", '-') ||
       ' | online order: ' || coalesce(o."OrderID" || ' (' || coalesce(o."Status", '-') || ')',
                                       'none - draft, assignable as AO-00039') ||
       case when exists (select 1 from public."DeliveryStops" s
                         where s."AutomatedOrderNo" = ao."OrderNo" or s."OrderID" = o."OrderID")
            then ' | already scheduled' else '' end
from public."AutomatedOrders" ao
left join public."OnlineOrders" o on o."OrderID" = nullif(trim(ao."PancakeReceiptNo"), '')
where ao."OrderNo" = 'AO-00039'
order by 1, 2;
