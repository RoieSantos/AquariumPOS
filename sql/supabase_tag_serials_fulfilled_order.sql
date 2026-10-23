-- Tag serials to an order AFTER it went out - per "can we create a button on the delivered if the products
-- dont have serials we can manually choose what serials they release". Online / Walk-in and Advance orders
-- that are Shipped / Delivered / Completed (picked up) but whose serial-tracked items have no serial (the
-- Stock FactBox's red "No serial tagged" - docs/js/itemStockFactbox.js) get a "Tag serial" link that opens
-- a picker (docs/js/onlineOrders.js openTagSerialsDialog). Same end state as picking them at Ready to Ship
-- (or the one-off supabase_tag_serial_order_AO-00040.sql): Status SOLD + SoldOnlineOrderId = the order's
-- link (OrderID, or 'ADV-' || TransactionNo with SoldReceiptNo), UpdatedAtUtc so the desktop POS pulls it.
--
--   staff_get_fulfilled_order_serial_candidates - one row per serial-tracked item (lines combined by item
--     code): total / tagged / still needed, and the serials that can be picked (IN_STOCK anywhere, or
--     RESERVED for this order) - this order's reserved ones first, then its own branch, then the line's
--     variant. Any branch / variant is allowed: the unit that really went out is whatever staff say it was.
--   staff_tag_serials_to_fulfilled_order - claims the picked ones. Refuses unless the order is fulfilled,
--     every serial is one of its serial-tracked items, no item gets more than it still needs, and every
--     serial is still IN_STOCK (or RESERVED for this order) - all or nothing.
-- Super User, Serial Admin or Production Manager only (_serial_can_manage_reservations) - it takes a unit
-- out of stock.
--
-- Run AFTER supabase_serial_order_reservation.sql, supabase_online_order_stock_status_set.sql and
-- supabase_advance_order_serials.sql (all live already). Safe to re-run.

-- Shipped / Delivered / Completed (walk-in picked up). Advance: its production row has Shipped or Delivered.
create or replace function public._serial_order_is_fulfilled(p_link text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_link ilike 'ADV-%' then exists (
      select 1 from public."AdvanceOrderProduction" p
      where p."TransactionNo" = substr(p_link, 5)
        and (p."ShippedAtUtc" is not null or p."DeliveredAtUtc" is not null))
    else exists (
      select 1 from public."OnlineOrders" o
      where o."OrderID" = p_link
        and (lower(trim(coalesce(o."Status", ''))) in ('shipped', 'delivered', 'completed')
             or (o."ReceivedAtShop" is true and o."PickedUpAtUtc" is not null)))
  end;
$$;

revoke execute on function public._serial_order_is_fulfilled(text) from public, anon, authenticated;

-- The order's serial-tracked items, by item code: total units, how many already have a SOLD serial.
create or replace function public._fulfilled_order_serial_needs(
  p_admin_username text, p_admin_password text, p_doc_type text, p_doc_no text)
returns table(item_code text, variation_id text, description text, quantity_total int, quantity_tagged int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_link text := public._serial_order_link(p_doc_type, p_doc_no);
begin
  if v_link ilike 'ADV-%' then
    return query
      select r.item_code, (array_agg(r.variation_id order by r.line_id))[1], (array_agg(r.description order by r.line_id))[1],
             sum(r.quantity_total)::int, sum(r.quantity_tagged)::int
      from public.staff_get_advance_order_serial_requirements(p_admin_username, p_admin_password, substr(v_link, 5)) r
      group by r.item_code;
  else
    return query
      select r.item_code, (array_agg(r.variation_id order by r.line_id))[1], (array_agg(r.description order by r.line_id))[1],
             sum(r.quantity_needed)::int,
             (select count(*)::int from public."ItemSerialTracking" s
              where s."SoldOnlineOrderId" = v_link and s."Status" = 'SOLD' and s."ItemCode" = r.item_code)
      from public.admin_get_online_order_serial_requirements(p_admin_username, p_admin_password, v_link) r
      group by r.item_code;
  end if;
end;
$$;

revoke execute on function public._fulfilled_order_serial_needs(text, text, text, text) from public, anon, authenticated;

drop function if exists public.staff_get_fulfilled_order_serial_candidates(text, text, text, text);

create or replace function public.staff_get_fulfilled_order_serial_candidates(
  p_admin_username text,
  p_admin_password text,
  p_doc_type text,   -- 'online' (Online / Walk-in) or 'advance'
  p_doc_no text
)
returns table(item_code text, description text, quantity_total int, quantity_tagged int, quantity_needed int,
              order_warehouse text, serials jsonb)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_link text := public._serial_order_link(p_doc_type, p_doc_no);
  v_warehouse text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._serial_can_manage_reservations(p_admin_username) then
    raise exception 'Only a Super User, Serial Admin or Production Manager can tag serials to an order.';
  end if;
  if v_link is null then
    raise exception 'Unknown order.';
  end if;

  v_warehouse := case when v_link ilike 'ADV-%'
    then (select nullif(trim(a."Warehouse"), '') from public."AdvanceOrders" a where a."TransactionNo" = substr(v_link, 5))
    else (select w."Name" from public."OnlineOrders" o join public."Warehouses" w on w."ID" = o."LocationID" where o."OrderID" = v_link)
  end;

  return query
    select n.item_code, coalesce(n.description, n.item_code), n.quantity_total, n.quantity_tagged,
           greatest(n.quantity_total - n.quantity_tagged, 0), v_warehouse,
           coalesce((
             select jsonb_agg(jsonb_build_object(
                      'running_serial_no', s."RunningSerialNo", 'serial_no', s."SerialNo",
                      'variant', s."VariantCode", 'location', s."Location",
                      'reserved', s."Status" = 'RESERVED', 'variant_match', coalesce(s."VariantCode", '') = coalesce(n.variation_id, ''))
                    order by s."Status" = 'RESERVED' desc,
                             lower(coalesce(trim(s."Location"), '')) = lower(coalesce(v_warehouse, '')) desc,
                             coalesce(s."VariantCode", '') = coalesce(n.variation_id, '') desc,
                             s."SerialNo")
             from (
               select * from public."ItemSerialTracking" x
               where x."ItemCode" = n.item_code
                 and (x."Status" = 'IN_STOCK' or (x."Status" = 'RESERVED' and x."ReservedForOrderId" = v_link))
               order by x."Status" = 'RESERVED' desc,
                        lower(coalesce(trim(x."Location"), '')) = lower(coalesce(v_warehouse, '')) desc,
                        x."SerialNo"
               limit 300
             ) s
           ), '[]'::jsonb)
    from public._fulfilled_order_serial_needs(p_admin_username, p_admin_password, p_doc_type, p_doc_no) n
    order by n.item_code;
end;
$$;

grant execute on function public.staff_get_fulfilled_order_serial_candidates(text, text, text, text) to anon;

drop function if exists public.staff_tag_serials_to_fulfilled_order(text, text, text, text, bigint[]);

create or replace function public.staff_tag_serials_to_fulfilled_order(
  p_admin_username text,
  p_admin_password text,
  p_doc_type text,
  p_doc_no text,
  p_running_nos bigint[]
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_link text := public._serial_order_link(p_doc_type, p_doc_no);
  v_picks bigint[] := coalesce(p_running_nos, '{}');
  v_receipt text;
  v_bad text;
  v_claimed int;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._serial_can_manage_reservations(p_admin_username) then
    raise exception 'Only a Super User, Serial Admin or Production Manager can tag serials to an order.';
  end if;
  if v_link is null then
    raise exception 'Unknown order.';
  end if;
  if coalesce(array_length(v_picks, 1), 0) = 0 then
    raise exception 'Pick at least one serial.';
  end if;
  if not public._serial_order_is_fulfilled(v_link) then
    raise exception 'Order % hasn''t been through To Ship yet - pick its serials at To Ship instead.', p_doc_no;
  end if;

  create temp table if not exists _tag_fulfilled_need (item_code text, quantity_total int, quantity_tagged int) on commit drop;
  truncate _tag_fulfilled_need;
  insert into _tag_fulfilled_need
    select n.item_code, n.quantity_total, n.quantity_tagged
    from public._fulfilled_order_serial_needs(p_admin_username, p_admin_password, p_doc_type, p_doc_no) n;

  select string_agg(coalesce(s."SerialNo", x.n::text), ', ') into v_bad
  from unnest(v_picks) x(n)
  left join public."ItemSerialTracking" s on s."RunningSerialNo" = x.n
  where s."RunningSerialNo" is null
     or not exists (select 1 from _tag_fulfilled_need r where r.item_code = s."ItemCode");
  if v_bad is not null then
    raise exception 'Serial(s) % don''t match any serial-tracked item on order %.', v_bad, p_doc_no;
  end if;

  select string_agg(r.item_code || ' (needs ' || greatest(r.quantity_total - r.quantity_tagged, 0) || ' more, picked ' || p.n || ')', ', ')
    into v_bad
  from _tag_fulfilled_need r
  join (
    select s."ItemCode" as item_code, count(*)::int as n
    from public."ItemSerialTracking" s where s."RunningSerialNo" = any(v_picks)
    group by 1
  ) p on p.item_code = r.item_code
  where p.n > r.quantity_total - r.quantity_tagged;
  if v_bad is not null then
    raise exception 'Too many serials for order %: %.', p_doc_no, v_bad;
  end if;

  if v_link ilike 'ADV-%' then
    select nullif(trim(a."ReceiptNo"), '') into v_receipt from public."AdvanceOrders" a where a."TransactionNo" = substr(v_link, 5);
  end if;

  with claimed as (
    update public."ItemSerialTracking"
       set "Status" = 'SOLD',
           "SoldOnlineOrderId" = v_link,
           "SoldReceiptNo" = case when v_link ilike 'ADV-%' then coalesce(v_receipt, "SoldReceiptNo") else "SoldReceiptNo" end,
           "UpdatedAtUtc" = now(),
           "UpdatedBy" = left(p_admin_username || ' (tagged after ship)', 100)
     where "RunningSerialNo" = any(v_picks)
       and ("Status" = 'IN_STOCK' or ("Status" = 'RESERVED' and "ReservedForOrderId" = v_link))
    returning 1
  )
  select count(*) into v_claimed from claimed;
  if v_claimed < array_length(v_picks, 1) then
    raise exception 'Only % of % selected serial(s) were still In Stock - someone may have just used one. Refresh and try again.', v_claimed, array_length(v_picks, 1);
  end if;

  -- Every unit tagged now: whatever is still held for the order is free again. Not before - tagging 1 of 2
  -- must leave the other unit's reservation in place.
  if not exists (
    select 1 from public._fulfilled_order_serial_needs(p_admin_username, p_admin_password, p_doc_type, p_doc_no) n
    where n.quantity_tagged < n.quantity_total
  ) then
    perform public._serial_release_order_reservations(v_link, p_admin_username);
  end if;

  return v_claimed;
end;
$$;

grant execute on function public.staff_tag_serials_to_fulfilled_order(text, text, text, text, bigint[]) to anon;
