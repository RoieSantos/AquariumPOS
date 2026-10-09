-- Advance Orders: tag serials at "Ready to Ship" in the portal - per "in advance order how can the user
-- tag the serials?" / "can we do that on the advance order portal too".
--
-- Before: only the desktop POS tagged advance-order serials, at Pay In Full, and only at a production
-- warehouse. The portal's Ready to Ship had no serial step. Now Ready to Ship works like an online
-- order's: pick In Stock serials, or "+ New serial" (created and label printed on the spot).
--
-- Link to the order: ItemSerialTracking."SoldOnlineOrderId" = 'ADV-' || TransactionNo. NOT the receipt
-- number - supabase_check_advance_order_receipt_serial_link.sql showed ReceiptNos repeat across stores
-- (every store counts RS-0000000001, ...), so a receipt alone can't say which order a serial belongs to.
-- TransactionNo is AdvanceOrders' primary key, the 'ADV-' prefix can never match a Pancake order ID, and
-- the POS already syncs SoldOnlineOrderId both ways (SyncItemSerialTrackingFromSupabaseAsync + push), so
-- the POS sees portal tags with no pull change. SoldReceiptNo is still filled (info only, like the POS).
-- The new POS build tags its own Pay In Full serials the same way (AdvanceOrdersHeaderForm.cs).
-- Older POS Pay In Full serials (receipt only) still count when that receipt is used by ONE advance order
-- and the serial sits at the order's warehouse - see _advance_order_serials.
--
-- Which lines need a serial: same rule as the POS's Pay In Full (IsSerialTrackedAdvanceOrderItemCode):
-- ITEM lines whose code starts AQ- / CUSTOM- / CUSTOM_, or whose item is in a production category.
--
--   staff_get_advance_order_serial_requirements - per item/variant: units needed, already tagged, still to tag.
--   staff_advance_order_to_ship_with_serials    - claims picked serials + creates new ones, then
--       staff_set_advance_order_stage(..., 'To Ship'), all in ONE transaction (any failure = nothing changes).
--       New serials only for a Super User or staff at a production warehouse (only production creates serials).
--   staff_get_advance_order_serial_labels      - every serial tied to the order, for (re)printing labels.
--
-- Run AFTER supabase_advance_order_production.sql and supabase_online_order_ship_new_serials.sql
-- (_production_next_serial_no). Safe to re-run. Needs js/onlineOrders.js ?v=advserial1.

-- ---------------------------------------------------------------------------
-- 0. The serials tied to an advance order (internal).

create or replace function public._advance_order_serials(p_no text)
returns setof public."ItemSerialTracking"
language sql
stable
security definer
set search_path = public
as $$
  with o as (
    select a."TransactionNo",
           nullif(trim(a."ReceiptNo"), '') as receipt,
           nullif(trim(a."Warehouse"), '') as warehouse,
           -- the receipt points at this order only
           (select count(*) from public."AdvanceOrders" x where x."ReceiptNo" = a."ReceiptNo") = 1 as receipt_unique
    from public."AdvanceOrders" a
    where a."TransactionNo" = p_no
  )
  select s.*
  from o
  join public."ItemSerialTracking" s
    on s."SoldOnlineOrderId" = 'ADV-' || o."TransactionNo"
    -- Older POS Pay In Full tags (receipt only): only when unambiguous.
    or (nullif(trim(s."SoldOnlineOrderId"), '') is null
        and o.receipt is not null and o.receipt_unique
        and s."SoldReceiptNo" = o.receipt
        and (o.warehouse is null or nullif(trim(s."Location"), '') is null
             or lower(trim(s."Location")) = lower(o.warehouse)));
$$;

revoke execute on function public._advance_order_serials(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. What still needs a serial.

drop function if exists public.staff_get_advance_order_serial_requirements(text, text, text);

create or replace function public.staff_get_advance_order_serial_requirements(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(
  line_id text,          -- item code + variant (one row per item/variant, lines combined)
  item_code text,
  variation_id text,
  description text,
  quantity_total int,
  quantity_tagged int,
  quantity_needed int    -- still to tag
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._advance_order_can_view(p_admin_username, p_no) then
    raise exception 'Not authorized.';
  end if;

  return query
    with lines as (
      select trim(l."No") as code,
             coalesce(nullif(trim(l."VariationId"), ''), nullif(trim(i."VariationId"), '')) as variant,
             nullif(trim(l."Description"), '') as descr,
             greatest(ceil(coalesce(l."Quantity", 0)), 0)::int as qty,
             l."LineNo" as line_no
      from public."AdvanceOrderLines" l
      left join public."Items" i on i."Code" = trim(l."No")
      left join public."Categories" c on c."Code" = i."CategoryCode"
      where l."TransactionNo" = p_no
        and upper(coalesce(l."Type", '')) = 'ITEM'
        and nullif(trim(l."No"), '') is not null
        and coalesce(l."Quantity", 0) > 0
        and (upper(trim(l."No")) like 'AQ-%'
             or left(upper(trim(l."No")), 7) in ('CUSTOM-', 'CUSTOM_')
             or coalesce(c."IsProductionCategory", false))
    ),
    grouped as (
      select code, variant,
             (array_agg(descr order by case when line_no ~ '^\d+$' then line_no::numeric end nulls last, line_no))[1] as descr,
             sum(qty)::int as total
      from lines
      group by code, variant
    ),
    tagged as (
      select s."ItemCode" as code, coalesce(s."VariantCode", '') as variant, count(*)::int as n
      from public._advance_order_serials(p_no) s
      where s."Status" = 'SOLD'
      group by 1, 2
    )
    select (g.code || coalesce('|' || g.variant, ''))::text,
           g.code::text,
           g.variant::text,
           coalesce(g.descr, g.code)::text,
           g.total,
           coalesce(t.n, 0),
           greatest(g.total - coalesce(t.n, 0), 0)
    from grouped g
    left join tagged t on t.code = g.code and t.variant = coalesce(g.variant, '')
    order by g.code, g.variant;
end;
$$;

grant execute on function public.staff_get_advance_order_serial_requirements(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 2. Ready to Ship with serials.

drop function if exists public.staff_advance_order_to_ship_with_serials(text, text, text, bigint[], jsonb);

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
       where "RunningSerialNo" = any(v_picks) and "Status" = 'IN_STOCK'
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

    if not coalesce(v_is_super, false) and not coalesce(v_staff_is_production, false) then
      raise exception 'Only a production warehouse can create new serials. Pick In Stock serials, or mark it Ready to Ship without them.';
    end if;

    v_location := coalesce(v_staff_warehouse, v_order_warehouse);

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

  return query select v_status, v_created;
end;
$$;

grant execute on function public.staff_advance_order_to_ship_with_serials(text, text, text, bigint[], jsonb) to anon;

-- ---------------------------------------------------------------------------
-- 3. Serial labels (reprint) - portal- and POS-tagged alike.

drop function if exists public.staff_get_advance_order_serial_labels(text, text, text);

create or replace function public.staff_get_advance_order_serial_labels(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(serial_no text, item_code text, description text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._advance_order_can_view(p_admin_username, p_no) then
    raise exception 'Not authorized.';
  end if;

  return query
    select s."SerialNo"::text, s."ItemCode"::text, coalesce(nullif(trim(s."ItemDescription"), ''), s."ItemCode")::text
    from public._advance_order_serials(p_no) s
    where coalesce(s."Status", '') <> 'REVERSED'
    order by s."ItemCode", s."SerialNo";
end;
$$;

grant execute on function public.staff_get_advance_order_serial_labels(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'function' as section, p.proname::text as item, pg_get_function_identity_arguments(p.oid) as detail
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('staff_get_advance_order_serial_requirements', 'staff_advance_order_to_ship_with_serials',
                    'staff_get_advance_order_serial_labels', '_production_next_serial_no', '_advance_order_serials')
order by 1, 2;
