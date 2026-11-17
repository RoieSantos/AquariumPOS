-- Advance Orders: a Production Manager can Change Item, and Undo Stage from To Ship frees the order's serials -
-- per "the status is to-ship already" / "can a production manager can do this?" / "yes both".
--
-- 1. Change Item (staff_change_advance_order_line_variant + its product search) now also allows a Production
--    Manager - ADVANCE orders only. Online orders stay Super User / Sales User.
-- 2. Undo Stage from To Ship (staff_set_advance_order_stage, p_stage null) puts every serial SOLD to the order
--    by the portal (SoldOnlineOrderId = 'ADV-<no>') back as RESERVED for that same order - not In Stock, so
--    nobody else can grab the unit meanwhile. Change Item is no longer blocked by them, and Ready to Ship
--    pre-picks them again; any it doesn't use (e.g. the line's item was changed) are freed to In Stock then
--    (_serial_release_order_reservations). Older POS Pay In Full serials linked by receipt only (no
--    SoldOnlineOrderId) are left alone - those still need a Super User's Mark In Stock.
--    Undo from Shipped / Delivered does not touch serials.
--
-- Copies of the newest versions: staff_set_advance_order_stage from supabase_advance_order_dispatcher_ship.sql,
-- staff_change_advance_order_line_variant / staff_search_order_line_variants from
-- supabase_order_line_change_variant.sql - with only the changes above.
-- Run AFTER supabase_advance_order_dispatcher_ship.sql, supabase_order_line_change_variant.sql and
-- supabase_serial_order_reservation.sql. Do NOT re-run those three afterwards (they'd put the old versions back) -
-- if you must, re-run this file after them. Safe to re-run. No table changes.
-- Needs js/onlineOrders.js ?v=advchgpm1.

-- ============================================================================
-- 1. Who may Change Item on an advance order
-- ============================================================================

create or replace function public._can_change_advance_order_line_item(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public._can_change_order_line_item(p_username) or public._production_is_manager(p_username);
$$;

revoke execute on function public._can_change_advance_order_line_item(text) from public, anon, authenticated;

-- ============================================================================
-- 2. Product search: a Production Manager only for an advance order line
-- ============================================================================

create or replace function public.staff_search_order_line_variants(
  p_admin_username text,
  p_admin_password text,
  p_variation_id text default null,     -- the line's current variant (online orders)
  p_item_code text default null,
  p_query text default null,
  p_advance_no text default null,       -- advance orders: resolve the line's variant from here instead
  p_advance_line_no text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_variation text := nullif(trim(coalesce(p_variation_id, '')), '');
  v_item text := nullif(trim(coalesce(p_item_code, '')), '');
  v_query text := nullif(trim(coalesce(p_query, '')), '');
  v_main text;
  v_result jsonb;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not (public._can_change_order_line_item(p_admin_username)
             or (p_advance_no is not null and public._production_is_manager(p_admin_username))) then
    raise exception 'Only a Super User or Sales User (or a Production Manager, on advance orders) can change an order line''s item.';
  end if;

  if p_advance_no is not null then
    select li.variation_id, li.item_code into v_variation, v_item
    from public._advance_order_line_items(p_advance_no) li
    where li.line_no = p_advance_line_no;
  end if;

  select c.main_item_code into v_main
  from public._order_line_variant_candidates() c
  where (v_variation is not null and c.variation_id = v_variation)
     or (v_variation is null and v_item is not null and (c.item_code = v_item or c.main_item_code = v_item))
  limit 1;
  v_main := coalesce(v_main, v_item);

  select coalesce(jsonb_agg(to_jsonb(r) order by r.is_current desc, r.name, r.sku), '[]'::jsonb) into v_result
  from (
    select distinct on (c.variation_id)
           c.variation_id, c.item_code, c.name, c.label, c.tag, c.description, c.sku, c.price,
           (c.variation_id = v_variation) as is_current
    from public._order_line_variant_candidates() c
    where (v_query is null and v_main is not null and (c.main_item_code = v_main or c.item_code = v_main))
       or (v_query is not null
           and (c.item_code || ' ' || c.name || ' ' || c.description || ' ' || c.sku) ilike '%' || v_query || '%')
    order by c.variation_id
    limit 60
  ) r;

  return jsonb_build_object('current_variation_id', v_variation, 'options', v_result);
end;
$$;

grant execute on function public.staff_search_order_line_variants(text, text, text, text, text, text, text) to anon;

-- ============================================================================
-- 3. Change Item on an advance order (only the permission check changed)
-- ============================================================================

create or replace function public.staff_change_advance_order_line_variant(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_line_no text,
  p_variation_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line public."AdvanceOrderLines";
  v_ov public."AdvanceOrderLineOverrides";
  v_has_ov boolean;
  v_new record;
  v_old_variation text;
  v_old_item text;
  v_pos_variation text;
  v_new_desc text;
  v_serial text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._can_change_advance_order_line_item(p_admin_username) then
    raise exception 'Only a Super User, Sales User or Production Manager can change an advance order line''s item.';
  end if;

  if exists (select 1 from public."AdvanceOrderProduction" p where p."TransactionNo" = p_no and p."ToShipAtUtc" is not null) then
    raise exception 'Advance order % is already at To Ship or later - Undo Stage back before To Ship first, then change the item.', p_no;
  end if;

  select * into v_line from public."AdvanceOrderLines" where "TransactionNo" = p_no and "LineNo" = p_line_no for update;
  if not found then
    raise exception 'Line % is no longer on advance order % - close and reopen the order.', p_line_no, p_no;
  end if;
  if upper(coalesce(v_line."Type", '')) <> 'ITEM' then
    raise exception 'Only item lines can be changed.';
  end if;

  select * into v_new from public._order_line_variant_candidates() c where c.variation_id = trim(coalesce(p_variation_id, '')) limit 1;
  if not found then
    raise exception 'That product isn''t linked to a Pancake variant - pick another one.';
  end if;

  select li.variation_id, li.item_code into v_old_variation, v_old_item
  from public._advance_order_line_items(p_no) li where li.line_no = p_line_no;
  if v_old_variation = v_new.variation_id then
    raise exception 'The line is already %.', v_new.label;
  end if;

  select s."SerialNo" into v_serial from public._advance_order_serials(p_no) s
  where s."Status" = 'SOLD' and s."ItemCode" = v_old_item and coalesce(s."VariantCode", '') = coalesce(v_old_variation, '')
  limit 1;
  if v_serial is not null then
    raise exception 'Serial % is already tagged to this line''s current variant (sold on the POS) - a Super User must Mark it In Stock in the Serial Tracker first.', v_serial;
  end if;

  v_new_desc := public._order_line_variant_swap_description(v_line."Description", v_old_variation, v_new.variation_id);

  select * into v_ov from public."AdvanceOrderLineOverrides" where "TransactionNo" = p_no and "LineNo" = p_line_no;
  v_has_ov := found;
  v_pos_variation := case when v_has_ov then v_ov."PosVariationId" else nullif(trim(v_line."VariationId"), '') end;

  if v_pos_variation is not distinct from v_new.variation_id then
    delete from public."AdvanceOrderLineOverrides" where "TransactionNo" = p_no and "LineNo" = p_line_no;
  else
    insert into public."AdvanceOrderLineOverrides"
      ("TransactionNo", "LineNo", "PosVariationId", "VariationId", "Description", "ChangedBy", "ChangedAtUtc")
    values (p_no, p_line_no, v_pos_variation, v_new.variation_id, left(v_new_desc, 500), p_admin_username, now())
    on conflict ("TransactionNo", "LineNo") do update
      set "VariationId" = excluded."VariationId", "Description" = excluded."Description",
          "ChangedBy" = excluded."ChangedBy", "ChangedAtUtc" = now();
  end if;

  update public."AdvanceOrderLines"
     set "VariationId" = v_new.variation_id, "Description" = left(v_new_desc, 500)
   where "TransactionNo" = p_no and "LineNo" = p_line_no;

  insert into public."OrderLineVariantChanges"
    ("OrderKind", "OrderNo", "LineNo", "OldVariationId", "OldDescription", "NewVariationId", "NewDescription", "ChangedBy")
  values ('Advance', p_no, p_line_no, v_old_variation, v_line."Description", v_new.variation_id, v_new_desc, p_admin_username);

  return jsonb_build_object('old_description', v_line."Description", 'new_description', v_new_desc);
end;
$$;

grant execute on function public.staff_change_advance_order_line_variant(text, text, text, text, text) to anon;

-- ============================================================================
-- 4. Stage changes - Undo from To Ship frees the order's serials (rest unchanged)
-- ============================================================================

create or replace function public.staff_set_advance_order_stage(
  p_admin_username text, p_admin_password text, p_no text, p_stage text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_stage text := nullif(trim(coalesce(p_stage, '')), '');
  v_prod public."AdvanceOrderProduction";
  v_status text;
  v_is_dispatcher boolean;
  v_branch text;
  v_link text := 'ADV-' || p_no;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Only a Super User or Production Manager can change this.';
  end if;
  if not exists (select 1 from public."AdvanceOrders" where "TransactionNo" = p_no) then
    raise exception 'Advance order % not found.', p_no;
  end if;

  if not public._production_is_manager(p_admin_username) then
    select coalesce('Dispatcher' = any(s."StaffRoles"), false), lower(nullif(trim(coalesce(s."WarehouseName", '')), ''))
      into v_is_dispatcher, v_branch
    from public."StaffUsers" s where s."Username" = p_admin_username and s."IsActive";
    if not coalesce(v_is_dispatcher, false) then
      raise exception 'Only a Super User or Production Manager can change this.';
    end if;
    if v_stage is distinct from 'Shipped' then
      raise exception 'A Dispatcher can only mark an advance order Shipped.';
    end if;
    if v_branch is not null and not exists (
      select 1 from public."AdvanceOrders" a
      where a."TransactionNo" = p_no and lower(trim(coalesce(a."Warehouse", ''))) = v_branch
    ) then
      raise exception 'Advance order % belongs to another branch.', p_no;
    end if;
  end if;

  insert into public."AdvanceOrderProduction" ("TransactionNo") values (p_no) on conflict do nothing;
  select * into v_prod from public."AdvanceOrderProduction" where "TransactionNo" = p_no for update;
  v_status := public._advance_order_prod_status(v_prod);

  if v_stage = 'To Ship' then
    if v_status = 'Assigned' then
      raise exception 'Advance order % is still in production - every assigned part must be Production Done first.', p_no;
    end if;
    update public."AdvanceOrderProduction"
       set "ToShipAtUtc" = now(), "ToShipBy" = p_admin_username, "ShippedAtUtc" = null, "ShippedBy" = null,
           "DeliveredAtUtc" = null, "DeliveredBy" = null
     where "TransactionNo" = p_no;
  elsif v_stage = 'Shipped' then
    if v_status is distinct from 'To Ship' then
      raise exception 'Advance order % must be To Ship before it can be marked Shipped.', p_no;
    end if;
    update public."AdvanceOrderProduction" set "ShippedAtUtc" = now(), "ShippedBy" = p_admin_username where "TransactionNo" = p_no;
  elsif v_stage is null then
    if v_status = 'Delivered' then
      update public."AdvanceOrderProduction" set "DeliveredAtUtc" = null, "DeliveredBy" = null where "TransactionNo" = p_no;
    elsif v_status = 'Shipped' then
      update public."AdvanceOrderProduction" set "ShippedAtUtc" = null, "ShippedBy" = null where "TransactionNo" = p_no;
    else
      update public."AdvanceOrderProduction" set "ToShipAtUtc" = null, "ToShipBy" = null where "TransactionNo" = p_no;
      -- (this file) Back from To Ship: the serials Ready to Ship sold to the order go back to RESERVED for it,
      -- so Change Item works and the next Ready to Ship pre-picks them (unused ones are freed there).
      if v_status = 'To Ship' then
        update public."ItemSerialTracking"
           set "Status" = 'RESERVED',
               "ReservedForOrderId" = v_link,
               "ReservedAtUtc" = now(),
               "ReservedBy" = left(p_admin_username || ' (Undo To Ship)', 100),
               "SoldOnlineOrderId" = null,
               "SoldReceiptNo" = null,
               "UpdatedAtUtc" = now(),
               "UpdatedBy" = p_admin_username
         where "SoldOnlineOrderId" = v_link and "Status" = 'SOLD';
      end if;
    end if;
  else
    raise exception 'p_stage must be ''To Ship'', ''Shipped'' or null.';
  end if;

  update public."AdvanceOrderProduction" set "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
   where "TransactionNo" = p_no
  returning * into v_prod;
  return public._advance_order_prod_status(v_prod);
end;
$$;

grant execute on function public.staff_set_advance_order_stage(text, text, text, text) to anon;

notify pgrst, 'reload schema';

-- Result: advance orders at To Ship right now and their portal-tagged serials (what an Undo would free).
select p."TransactionNo" as advance_no,
       count(s."SerialNo") as serials_undo_would_reserve,
       string_agg(s."SerialNo" || ' ' || s."ItemCode", ', ') as serials
from public."AdvanceOrderProduction" p
left join public."ItemSerialTracking" s on s."SoldOnlineOrderId" = 'ADV-' || p."TransactionNo" and s."Status" = 'SOLD'
where p."ToShipAtUtc" is not null and p."ShippedAtUtc" is null
group by p."TransactionNo"
order by p."TransactionNo";
