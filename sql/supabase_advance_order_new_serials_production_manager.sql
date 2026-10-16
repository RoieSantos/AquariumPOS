-- Advance Orders: a Production Manager can create new serials at Ready to Ship, whatever their warehouse -
-- per "if i change my production manager to all warehouse.. the production manager now cannot print
-- serials".
--
-- Before: staff_advance_order_to_ship_with_serials only let a Super User, or staff whose OWN warehouse
-- (StaffUsers.WarehouseName) is a production warehouse, create "+ New serial". A Production Manager set
-- to all warehouses (blank WarehouseName) was refused with "Only a production warehouse can create new
-- serials", so no serial was made and no label printed. Online Orders' Ready to Ship never had this check.
--
-- Now: the function's own gate (_production_is_manager = Super User or Production Manager) is enough to
-- create new serials. Where the new serial sits (Location): the caller's warehouse if it's a production
-- warehouse (unchanged), otherwise the advance order's own branch (AdvanceOrders."Warehouse"), otherwise
-- the caller's warehouse.
--
-- Copy of supabase_serial_order_reservation.sql's version (the newest) with only that block changed.
-- Run AFTER supabase_serial_order_reservation.sql. Do NOT re-run supabase_serial_order_reservation.sql or
-- supabase_advance_order_serials.sql afterwards - they would put the old check back.
-- Safe to re-run. Replaces one function - no table changes.

create or replace function public.staff_advance_order_to_ship_with_serials(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_serial_running_nos bigint[] default null,
  -- [{"item_code": "...", "variation_id": "...", "description": "...", "quantity": 1}, ...]
  p_new_serials jsonb default null
)
returns table(new_status text, created_serials jsonb)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '50000'
as $$
declare
  v_link text := 'ADV-' || p_no;
  v_receipt text;
  v_order_warehouse text;
  v_is_super boolean;
  v_staff_warehouse text;
  v_staff_is_production boolean;
  v_location text;
  v_picks bigint[] := coalesce(p_serial_running_nos, '{}');
  v_has_new boolean := p_new_serials is not null and jsonb_typeof(p_new_serials) = 'array' and jsonb_array_length(p_new_serials) > 0;
  v_bad text;
  v_claimed int;
  v_req record;
  v_serial text;
  v_created jsonb := '[]'::jsonb;
  v_status text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Super User or Production Manager can change this.';
  end if;

  select nullif(trim(a."ReceiptNo"), ''), nullif(trim(a."Warehouse"), '')
    into v_receipt, v_order_warehouse
  from public."AdvanceOrders" a where a."TransactionNo" = p_no;
  if not found then
    raise exception 'Advance order % not found.', p_no;
  end if;

  if array_length(v_picks, 1) > 0 or v_has_new then
    -- Every requested unit must belong to a serial-tracked line that still needs one: picks + new per
    -- item/variant never more than "still to tag".
    create temp table if not exists _adv_serial_req (item_code text, variation_id text, description text, quantity_needed int) on commit drop;
    truncate _adv_serial_req;
    insert into _adv_serial_req
      select r.item_code, r.variation_id, r.description, r.quantity_needed
      from public.staff_get_advance_order_serial_requirements(p_admin_username, p_admin_password, p_no) r;

    select string_agg(coalesce(s."SerialNo", x.n::text), ', ') into v_bad
    from unnest(v_picks) x(n)
    left join public."ItemSerialTracking" s on s."RunningSerialNo" = x.n
    where s."RunningSerialNo" is null
       or not exists (select 1 from _adv_serial_req r
                      where r.item_code = s."ItemCode" and coalesce(r.variation_id, '') = coalesce(s."VariantCode", ''));
    if v_bad is not null then
      raise exception 'Serial(s) % don''t match any item on advance order % that needs a serial.', v_bad, p_no;
    end if;

    -- Picked serials must be at the order's own branch (AdvanceOrders."Warehouse") - same as the picker.
    if v_order_warehouse is not null then
      select string_agg(s."SerialNo" || ' (at ' || coalesce(nullif(trim(s."Location"), ''), 'no location') || ')', ', ') into v_bad
      from public."ItemSerialTracking" s
      where s."RunningSerialNo" = any(v_picks)
        and lower(coalesce(trim(s."Location"), '')) <> lower(v_order_warehouse);
      if v_bad is not null then
        raise exception 'Serial(s) % aren''t at %, the branch of advance order %.', v_bad, v_order_warehouse, p_no;
      end if;
    end if;

    select string_agg(r.item_code || ' (needs ' || r.quantity_needed || ', got ' || (coalesce(p.n, 0) + coalesce(nw.n, 0)) || ')', ', ')
      into v_bad
    from _adv_serial_req r
    left join (
      select s."ItemCode" as item_code, coalesce(s."VariantCode", '') as variant, count(*)::int as n
      from public."ItemSerialTracking" s where s."RunningSerialNo" = any(v_picks)
      group by 1, 2
    ) p on p.item_code = r.item_code and p.variant = coalesce(r.variation_id, '')
    left join (
      select x.item_code, coalesce(x.variation_id, '') as variant, sum(coalesce(x.quantity, 0))::int as n
      from jsonb_to_recordset(case when v_has_new then p_new_serials else '[]'::jsonb end)
           as x(item_code text, variation_id text, description text, quantity int)
      group by 1, 2
    ) nw on nw.item_code = r.item_code and nw.variant = coalesce(r.variation_id, '')
    where coalesce(p.n, 0) + coalesce(nw.n, 0) > r.quantity_needed;
    if v_bad is not null then
      raise exception 'Too many serials for advance order %: %.', p_no, v_bad;
    end if;

    if v_has_new and exists (
      select 1 from jsonb_to_recordset(p_new_serials) as x(item_code text, variation_id text, description text, quantity int)
      where coalesce(x.quantity, 0) < 1
         or not exists (select 1 from _adv_serial_req r
                        where r.item_code = x.item_code and coalesce(r.variation_id, '') = coalesce(x.variation_id, ''))) then
      raise exception 'A new serial was requested for an item that isn''t a serial-tracked line on advance order %.', p_no;
    end if;
  end if;

  -- Claim the picked In Stock serials.
  if array_length(v_picks, 1) > 0 then
    with claimed as (
      update public."ItemSerialTracking"
         set "Status" = 'SOLD',
             "SoldOnlineOrderId" = v_link,
             "SoldReceiptNo" = coalesce(v_receipt, "SoldReceiptNo"),
             "UpdatedAtUtc" = now(),
             "UpdatedBy" = p_admin_username
       where "RunningSerialNo" = any(v_picks)
         -- supabase_serial_order_reservation.sql: or held for THIS order
         and ("Status" = 'IN_STOCK' or ("Status" = 'RESERVED' and "ReservedForOrderId" = v_link))
      returning 1
    )
    select count(*) into v_claimed from claimed;
    if v_claimed < array_length(v_picks, 1) then
      raise exception 'Only % of % selected serial(s) were still In Stock - someone may have just used one. Refresh and try again.', v_claimed, array_length(v_picks, 1);
    end if;
  end if;

  -- Create new serials (production only), SOLD to this order, numbered like the desktop.
  if v_has_new then
    select coalesce(s."SuperUser", false), nullif(trim(s."WarehouseName"), '')
      into v_is_super, v_staff_warehouse
    from public."StaffUsers" s where s."Username" = p_admin_username;

    select coalesce(bool_or(coalesce(w."IsProductionWarehouse", false)), false) into v_staff_is_production
    from public."Warehouses" w
    where v_staff_warehouse is not null and w."Name" = v_staff_warehouse;

    -- (this file) No production-warehouse check: the gate at the top already limits this function to a
    -- Super User or Production Manager, with or without a warehouse. A unit made at a production
    -- warehouse sits there; otherwise (all warehouses / a store) it sits at the order's own branch.
    v_location := case when coalesce(v_staff_is_production, false) then v_staff_warehouse
                       else coalesce(v_order_warehouse, v_staff_warehouse) end;

    for v_req in
      select * from jsonb_to_recordset(p_new_serials) as x(item_code text, variation_id text, description text, quantity int)
    loop
      for i in 1..v_req.quantity loop
        v_serial := public._production_next_serial_no(v_req.item_code);
        -- UpdatedAtUtc set so the desktop POS pulls it down (SyncItemSerialTrackingFromSupabaseAsync).
        insert into public."ItemSerialTracking"
          ("SerialNo", "ItemCode", "ItemDescription", "Location", "Status", "SourceDocumentNo", "CreatedBy",
           "VariantCode", "SoldOnlineOrderId", "SoldReceiptNo", "UpdatedAtUtc", "UpdatedBy")
        values
          (v_serial, v_req.item_code, left(coalesce(nullif(trim(v_req.description), ''), v_req.item_code), 255), v_location,
           'SOLD', v_link, p_admin_username,
           nullif(trim(coalesce(v_req.variation_id, '')), ''), v_link, v_receipt, now(), p_admin_username);
        v_created := v_created || jsonb_build_array(jsonb_build_object(
          'serial_no', v_serial, 'item_code', v_req.item_code,
          'description', coalesce(nullif(trim(v_req.description), ''), v_req.item_code)));
      end loop;
    end loop;
  end if;

  -- The stage change itself (raises if production isn't done - which rolls the serials back too).
  v_status := public.staff_set_advance_order_stage(p_admin_username, p_admin_password, p_no, 'To Ship');

  -- supabase_serial_order_reservation.sql: leftover reservations (other units were picked) are freed.
  perform public._serial_release_order_reservations(v_link, p_admin_username);

  return query select v_status, v_created;
end;
$$;

grant execute on function public.staff_advance_order_to_ship_with_serials(text, text, text, bigint[], jsonb) to anon;
