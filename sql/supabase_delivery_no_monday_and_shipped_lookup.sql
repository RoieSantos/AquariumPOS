-- Two Delivery changes:
-- 1. Mondays are blocked as a delivery date - no truck runs that day. Enforced here (the actual
--    write path) in admin_create_delivery_stop and admin_move_delivery_stop; delivery.js also
--    marks Mondays "No Delivery" on the calendar and blocks the Assign modal client-side, but
--    this server-side check is what actually stops it regardless of the UI.
-- 2. admin_list_deliverable_online_orders now also surfaces "Shipped" orders (previously only
--    Confirmed/Printed/To Ship), so they can be looked up and assigned to a delivery date too.

create or replace function public.admin_list_deliverable_online_orders(p_admin_username text, p_admin_password text, p_search text default null, p_page int default 1, p_page_size int default 50)
returns table(
  order_id text,
  customer_name text,
  status text,
  shipping_address text,
  money_to_collect numeric,
  balance numeric,
  estimated_delivery_date date,
  scheduled_date date,
  stop_id uuid,
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
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select o."OrderID"::text, o."CustomerName"::text, o."Status"::text, o."ShippingAddress"::text,
           o."MoneyToCollect", o."Balance", o."EstimatedDeliveryDate",
           s."DeliveryDate", s."StopID",
           count(*) over()
    from public."OnlineOrders" o
    left join public."DeliveryStops" s on s."OrderID" = o."OrderID"
    where o."ForDelivery" is not true
      and lower(o."Status") in ('confirmed', 'printed', 'to ship', 'shipped')
      and (
        p_search is null or trim(p_search) = ''
        or o."OrderID" ilike '%' || p_search || '%'
        or o."CustomerName" ilike '%' || p_search || '%'
      )
    order by o."Last_Updated_At" desc nulls last
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

create or replace function public.admin_create_delivery_stop(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_delivery_date date,
  p_truck_id uuid default null,
  p_notes text default null
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
    insert into public."DeliveryStops" ("OrderID", "TruckID", "DeliveryDate", "StopSequence", "Notes", "CreatedBy")
    values (p_order_id, v_truck_id, p_delivery_date, v_next_sequence, p_notes, p_admin_username)
    returning "StopID" into v_id;
  exception when unique_violation then
    raise exception 'This order is already scheduled for that date.';
  end;

  update public."OnlineOrders" set "ForDelivery" = true where "OrderID" = p_order_id;

  return v_id;
end;
$$;

create or replace function public.admin_move_delivery_stop(p_admin_username text, p_admin_password text, p_stop_id uuid, p_new_date date)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_truck_id uuid;
  v_next_sequence int;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if extract(dow from p_new_date) = 1 then
    raise exception 'Mondays are not available for delivery.';
  end if;

  select "TruckID" into v_truck_id from public."DeliveryStops" where "StopID" = p_stop_id;
  if not found then
    raise exception 'Delivery stop not found.';
  end if;

  select coalesce(max("StopSequence") + 1, 0) into v_next_sequence
  from public."DeliveryStops"
  where "DeliveryDate" = p_new_date and "TruckID" = v_truck_id and "StopID" <> p_stop_id;

  begin
    update public."DeliveryStops"
    set "DeliveryDate" = p_new_date, "StopSequence" = v_next_sequence
    where "StopID" = p_stop_id;
  exception when unique_violation then
    raise exception 'This order is already scheduled for that date.';
  end;
end;
$$;
