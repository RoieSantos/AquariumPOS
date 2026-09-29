-- Online Orders: ship stock tank / stand / sump orders from serials in stock, or build the missing units
-- through a Production Order - per "in the online orders.. if the orders is tank / stand or sump can we
-- check the serials if there are no serials available is it possible we can assign the order? then if
-- there is an serial can we to-ship the order directly?".
--
-- Applies to orders whose serial-tracked lines are STOCK items (AQ-..., production categories - the same
-- rule as admin_get_online_order_serial_requirements) and have no custom line (custom lines keep the
-- Assign -> makers -> Production Done flow). Stock is counted at the ORDER'S branch (OnlineOrders.LocationID
-- -> Warehouses.Name = ItemSerialTracking.Location).
--   * every unit has an IN_STOCK serial there -> Ready to Ship straight away (admin_ship_online_order_from_stock)
--   * some don't -> "Assign" creates a Production Order for the missing units, linked to the order
--     (ProductionOrders.SourceOnlineOrderId); once its output posts the serials, the order can ship.
--
--   ProductionOrders.SourceOnlineOrderId            - which online order a build is for.
--   staff_get_online_order_stock_status(orders[])   - per order: stock lines, needed vs available, and the
--                                                     linked production order (if any).
--   staff_link_production_order_to_online_order     - sets that link (Production Manager / Super User).
--   admin_ship_online_order_from_stock(...)         - To Ship from Confirmed / Printed for such an order:
--                                                     same as admin_update_online_order_status (Pancake,
--                                                     serial claim, customer message), allowed from Confirmed.
--
-- Run AFTER supabase_online_order_status_message_gma.sql and supabase_production_orders.sql. Safe to re-run.

alter table public."ProductionOrders" add column if not exists "SourceOnlineOrderId" varchar(50);
create index if not exists "IX_ProductionOrders_SourceOnlineOrderId" on public."ProductionOrders" ("SourceOnlineOrderId");

-- ---------------------------------------------------------------------------
drop function if exists public.staff_get_online_order_stock_status(text, text, text[]);

create or replace function public.staff_get_online_order_stock_status(
  p_admin_username text,
  p_admin_password text,
  p_order_ids text[]
)
returns table(order_id text, warehouse_name text, has_custom_line boolean, needs_serial boolean,
              all_available boolean, lines jsonb, production_order_no text, production_order_status text)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with orders as (
      select o."OrderID"::text as order_id, w."Name"::text as warehouse_name
      from public."OnlineOrders" o
      left join public."Warehouses" w on w."ID" = o."LocationID"
      where o."OrderID"::text = any(coalesce(p_order_ids, '{}'))
    ),
    resolved as (
      select ord.order_id, ord.warehouse_name,
             nullif(trim(l."VariationId"), '') as variation_id,
             l."Description" as description,
             greatest(1, ceil(coalesce(l."Quantity", 1)))::int as qty,
             public._online_order_line_part(l."Description", l."ItemCode", l."product_display_id") as custom_part,
             coalesce(nullif(trim(v."ItemCode"), ''), nullif(trim(i."Code"), ''), nullif(trim(l."ItemCode"), '')) as item_code,
             coalesce(v."CategoryCode", i."CategoryCode") as category_code
      from orders ord
      join public."OnlineOrderLines" l on l."OrderID"::text = ord.order_id
      left join public."Variants" v on nullif(trim(l."VariationId"), '') is not null and v."VariationId" = l."VariationId"
      left join public."Items" i on i."Code" = l."ItemCode" or i."VariationId" = l."ItemCode"
    ),
    stock_lines as (
      select r.order_id, r.warehouse_name, r.item_code, r.variation_id, min(r.description) as description, sum(r.qty)::int as needed
      from resolved r
      left join public."Categories" c on c."Code" = r.category_code
      where r.custom_part is null
        and r.item_code is not null
        and (upper(r.item_code) like 'AQ-%' or coalesce(c."IsProductionCategory", false))
      group by r.order_id, r.warehouse_name, r.item_code, r.variation_id
    ),
    counted as (
      select sl.*,
             (select count(*)::int from public."ItemSerialTracking" s
              where s."Status" = 'IN_STOCK'
                and s."ItemCode" = sl.item_code
                and coalesce(nullif(trim(s."VariantCode"), ''), '') = coalesce(sl.variation_id, '')
                and s."Location" = sl.warehouse_name) as available
      from stock_lines sl
    )
    select ord.order_id,
           ord.warehouse_name,
           exists (select 1 from resolved r where r.order_id = ord.order_id and r.custom_part is not null),
           exists (select 1 from counted c where c.order_id = ord.order_id),
           coalesce(bool_and(c.available >= c.needed) filter (where c.order_id is not null), false),
           coalesce(jsonb_agg(jsonb_build_object(
             'item_code', c.item_code, 'variation_id', c.variation_id, 'description', c.description,
             'needed', c.needed, 'available', c.available,
             'variant_name', (select coalesce(nullif(trim(v."VariantName"), ''), v."SKU") from public."Variants" v where v."VariationId" = c.variation_id)
           ) order by c.item_code) filter (where c.order_id is not null), '[]'::jsonb),
           (select po."No"::text from public."ProductionOrders" po
             where po."SourceOnlineOrderId" = ord.order_id
             order by (po."Status" <> 'Finished') desc, po."CreatedAtUtc" desc limit 1),
           (select po."Status"::text from public."ProductionOrders" po
             where po."SourceOnlineOrderId" = ord.order_id
             order by (po."Status" <> 'Finished') desc, po."CreatedAtUtc" desc limit 1)
    from orders ord
    left join counted c on c.order_id = ord.order_id
    group by ord.order_id, ord.warehouse_name;
end;
$$;

grant execute on function public.staff_get_online_order_stock_status(text, text, text[]) to anon;

-- ---------------------------------------------------------------------------
drop function if exists public.staff_link_production_order_to_online_order(text, text, text, text);

create or replace function public.staff_link_production_order_to_online_order(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_order_id text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Production Manager can link a production order.';
  end if;
  update public."ProductionOrders"
    set "SourceOnlineOrderId" = nullif(trim(coalesce(p_order_id, '')), ''), "UpdatedAtUtc" = now()
    where "No" = p_no;
  if not found then
    raise exception 'Production order % not found.', p_no;
  end if;
end;
$$;

grant execute on function public.staff_link_production_order_to_online_order(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- To Ship straight from Confirmed for an order shipping from stock. admin_update_online_order_status
-- only allows To Ship from Printed / Assigned (the desktop prints first); here the order is treated as
-- Printed inside the SAME transaction, then that function runs as usual (serial claim, new serials,
-- Pancake PATCH to To Ship, customer message). If anything fails - e.g. Pancake can't be reached - the
-- whole call rolls back and the order stays as it was.
drop function if exists public.admin_ship_online_order_from_stock(text, text, text, text, boolean, bigint[], jsonb);

create or replace function public.admin_ship_online_order_from_stock(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_new_status text,
  p_notify_customer boolean,
  p_serial_running_nos bigint[] default null,
  p_new_serials jsonb default null
)
returns table(new_status text, message_sent boolean, message_error text, created_serials jsonb,
              gma_psid text, gma_message text)
language plpgsql
security definer
set search_path = public, extensions
-- Kept UNDER the API gateway's ~60s limit: past it the gateway drops the connection with no CORS
-- headers and the browser only says "TypeError: Failed to fetch" (per "still erroring on the to-ship").
-- Waiting on the order's row lock (a background Pancake sync or an earlier attempt still running) now
-- gives up after 10s with a readable error instead of hanging until the gateway cuts it.
set statement_timeout = '50000'
set lock_timeout = '10000'
as $$
declare
  v_status text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not exists (
    select 1 from public."StaffUsers" s
    where s."Username" = p_admin_username and s."IsActive"
      and (s."SuperUser" or 'ProductionManager' = any(coalesce(s."StaffRoles", '{}')))
  ) then
    raise exception 'Only a Production Manager can ship an order from stock.';
  end if;

  begin
    select lower(trim(coalesce("Status", ''))) into v_status from public."OnlineOrders" where "OrderID" = p_order_id for update;
  exception when lock_not_available then
    raise exception 'Order % is busy (a sync or another update is still running on it). Wait a minute, refresh and try again.', p_order_id;
  end;
  if v_status is null then
    raise exception 'Order % not found.', p_order_id;
  end if;
  if v_status not in ('confirmed', 'submitted', 'printed', 'assigned') then
    raise exception 'Order % is %, it can''t go To Ship from here.', p_order_id, v_status;
  end if;
  if coalesce(array_length(p_serial_running_nos, 1), 0) = 0 then
    raise exception 'Pick the in-stock serial(s) for this order first.';
  end if;

  if v_status in ('confirmed', 'submitted') then
    update public."OnlineOrders" set "Status" = 'Printed' where "OrderID" = p_order_id;
  end if;

  return query
    select * from public.admin_update_online_order_status(
      p_admin_username, p_admin_password, p_order_id, p_new_status, p_notify_customer,
      p_serial_running_nos, p_new_serials);
end;
$$;

grant execute on function public.admin_ship_online_order_from_stock(text, text, text, text, boolean, bigint[], jsonb) to anon;

-- ---------------------------------------------------------------------------
-- The order's current portal status - the page asks this after a status change comes back as
-- "Failed to fetch" (connection dropped), to tell whether the change went through anyway.
drop function if exists public.staff_get_online_order_current_status(text, text, text);

create or replace function public.staff_get_online_order_current_status(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return (select "Status"::text from public."OnlineOrders" where "OrderID" = p_order_id);
end;
$$;

grant execute on function public.staff_get_online_order_current_status(text, text, text) to anon;

notify pgrst, 'reload schema';
