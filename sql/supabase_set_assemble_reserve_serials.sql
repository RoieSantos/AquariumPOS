-- SET Assemble picks the serials and RESERVES them for the order - per "for set serials should be picked
-- at assemble so the serials should be reserved and cannot pick".
--
-- Before: Assemble only chose WHICH parts (variant / sealant colour) go into the SET. The in-stock tank /
-- sump stayed plain IN_STOCK until Ready to Ship, so while a short part (e.g. the stand) was being built,
-- a walk-in sale, POS Pay In Full or another order's Ready to Ship could take them.
--
-- Now, in the Assemble dialog every serial-tracked part that has stock at the order's branch must have
-- its serial(s) picked (the oldest are pre-ticked). Confirm reserves them for the order
-- (Status 'RESERVED', ReservedForOrderId = the order - supabase_serial_order_reservation.sql), so no other
-- picker can offer them. Parts with no stock aren't picked: Assign builds them, and their Production
-- Output is reserved for the order automatically. Ready to Ship pre-fills the reserved serials.
--
--   staff_list_set_part_serials(order, item, variation)  - the serials a part can take: IN_STOCK at the
--     order's branch + any already RESERVED for this order (re-opening Assemble), oldest first.
--   staff_assemble_online_order_set(order, sets, serial_nos) - ONE transaction: frees this order's
--     earlier Assemble reservations that weren't picked again, reserves the picked serials (each must
--     still be IN_STOCK at the branch or already reserved for this order, and be one of the parts being
--     saved), then runs staff_save_online_order_set_materials (the live version from
--     supabase_bot_orders_portal_confirm.sql - not copied here). If the Pancake save fails, the
--     reservations roll back with it.
-- Assemble reservations are tagged ReservedBy = '<username> (Assemble)' so a re-Assemble only frees its
-- own - never a Production Output or Serial Tracker reservation.
--
-- Run AFTER supabase_serial_order_reservation.sql and supabase_bot_orders_portal_confirm.sql. Safe to
-- re-run.

drop function if exists public.staff_list_set_part_serials(text, text, text, text, text);

create or replace function public.staff_list_set_part_serials(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_item_code text,
  p_variation_id text default null
)
returns table(running_serial_no bigint, serial_no text, reserved boolean)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare
  v_wh text := public._online_order_warehouse_name(p_order_id);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select s."RunningSerialNo", s."SerialNo"::text, (s."Status" = 'RESERVED')
    from public."ItemSerialTracking" s
    where s."ItemCode" = p_item_code
      -- same variant match as Assemble's stock count (_set_serials_in_stock)
      and coalesce(nullif(trim(s."VariantCode"), ''), '') = coalesce(nullif(trim(p_variation_id), ''), '')
      and ((s."Status" = 'IN_STOCK' and v_wh is not null and s."Location" = v_wh)
           or (s."Status" = 'RESERVED' and s."ReservedForOrderId" = p_order_id))
    order by (s."Status" = 'RESERVED') desc, s."CreatedAtUtc" nulls last, s."RunningSerialNo";
end;
$$;

grant execute on function public.staff_list_set_part_serials(text, text, text, text, text) to anon;

drop function if exists public.staff_assemble_online_order_set(text, text, text, jsonb, text[]);

create or replace function public.staff_assemble_online_order_set(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_sets jsonb,
  p_serial_nos text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '50000'
as $$
declare
  v_wh text := public._online_order_warehouse_name(p_order_id);
  v_picks text[] := array(select distinct trim(x) from unnest(coalesce(p_serial_nos, '{}')) x where nullif(trim(x), '') is not null);
  v_tag text := left(p_admin_username || ' (Assemble)', 100);
  v_bad text;
  v_count int;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  -- Only matters when something is being reserved - a SET with no tracked parts assembles as before.
  if coalesce(array_length(v_picks, 1), 0) > 0 and not public._serial_order_is_open(p_order_id) then
    raise exception 'Order % is already cancelled, shipped or picked up - its serials can''t be reserved.', p_order_id;
  end if;

  -- Every pick must be one of the parts being saved.
  select string_agg(s."SerialNo", ', ') into v_bad
  from public."ItemSerialTracking" s
  where s."SerialNo" = any(v_picks)
    and not exists (
      select 1
      from jsonb_array_elements(coalesce(p_sets, '[]'::jsonb)) st
      cross join lateral jsonb_array_elements(coalesce(st -> 'materials', '[]'::jsonb)) m
      where (nullif(m ->> 'item_code', '') = s."ItemCode"
             or exists (select 1 from public."Variants" v
                        where v."VariationId" = m ->> 'variation_id'
                          and coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode") = s."ItemCode")));
  if v_bad is not null then
    raise exception 'Serial(s) % don''t belong to any part being assembled.', v_bad;
  end if;

  -- Earlier Assemble reservations of this order that weren't picked again go back In Stock.
  update public."ItemSerialTracking"
     set "Status" = 'IN_STOCK', "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
   where "Status" = 'RESERVED' and "ReservedForOrderId" = p_order_id
     and "ReservedBy" like '% (Assemble)'
     and not ("SerialNo" = any(v_picks));

  -- Reserve the picks: still IN_STOCK at the order's branch, or already held for this order.
  with done as (
    update public."ItemSerialTracking"
       set "Status" = 'RESERVED', "ReservedForOrderId" = p_order_id, "ReservedAtUtc" = now(),
           "ReservedBy" = v_tag, "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
     where "SerialNo" = any(v_picks)
       and (("Status" = 'IN_STOCK' and v_wh is not null and "Location" = v_wh)
            or ("Status" = 'RESERVED' and "ReservedForOrderId" = p_order_id))
    returning "SerialNo"
  )
  select count(*) into v_count from done;

  if v_count < coalesce(array_length(v_picks, 1), 0) then
    select string_agg(x || ' (' || coalesce(s."Status", 'not found')
                      || case when s."Status" = 'RESERVED' then ' for ' || coalesce(s."ReservedForOrderId", '?')
                              when s."Status" = 'IN_STOCK' then ' at ' || coalesce(s."Location", '?') else '' end || ')', ', ')
      into v_bad
    from unnest(v_picks) x
    left join public."ItemSerialTracking" s on s."SerialNo" = x
    where s."SerialNo" is null
       or not ((s."Status" = 'RESERVED' and s."ReservedForOrderId" = p_order_id));
    raise exception 'These serials are no longer available for this order: %. Close Assemble and open it again.', coalesce(v_bad, '?');
  end if;

  -- The parts themselves (Pancake + OnlineOrderLines). Raises on failure -> the reservations roll back.
  return public.staff_save_online_order_set_materials(p_admin_username, p_admin_password, p_order_id, p_sets);
end;
$$;

grant execute on function public.staff_assemble_online_order_set(text, text, text, jsonb, text[]) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'function' as section, p.proname::text as item, pg_get_function_identity_arguments(p.oid) as detail
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('staff_list_set_part_serials', 'staff_assemble_online_order_set',
                    'staff_save_online_order_set_materials', '_serial_order_is_open')
order by 2;
