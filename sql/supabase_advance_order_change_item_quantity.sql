-- Advance Orders: Change Item for PART of a line's quantity - per "if we exchange the item to another item..
-- can we put the qty on how many will it exchange?".
--
-- staff_change_advance_order_line_variant gets p_quantity (how many units change; null / the whole line = the
-- old behaviour, the whole line changes). Less than the line's quantity SPLITS the line:
--   - the original line keeps the old item with the rest of the quantity (e.g. 3 -> 2),
--   - a NEW line "<LineNo>-X1" (then -X2, ...) gets the new item with the changed quantity (e.g. 1).
--   Price per unit stays; Discount / Gross / Net are split by quantity (rounding remainder stays on the
--   original line), so the order total doesn't change.
--
-- Why it survives the POS sync: the POS pushes AdvanceOrderLines by UPSERT on (TransactionNo, LineNo) and
-- never deletes, so a portal-made "-X" line is never touched (the POS numbers its own lines 1, 2, 3...). The
-- original line's reduced quantity is kept in AdvanceOrderLineOverrides (new PosQuantity / Quantity /
-- Discount / GrossAmount / NetAmount columns): the BEFORE trigger re-applies it whenever the POS sends the
-- line with its ORIGINAL quantity. If the POS sends a different quantity (really edited on the POS), the POS
-- wins and the quantity override is dropped - check the order's "-X" line by hand then.
-- A portal "-X" line is edited directly (no override - the POS never sends it).
-- The Item Ledger follows on its own (TR_AdvanceOrderLines_ItemLedger reconciles all of the order's lines).
-- Every change is logged in OrderLineVariantChanges (new Quantity / NewLineNo columns).
--
-- Run AFTER supabase_advance_order_change_item_production_manager.sql (replaces its
-- staff_change_advance_order_line_variant; keeps its Production Manager permission). Do NOT re-run
-- supabase_order_line_change_variant.sql or supabase_advance_order_change_item_production_manager.sql
-- afterwards - if you must, re-run this file after them. Safe to re-run.
-- Needs js/onlineOrders.js ?v=advchgqty1.

-- ============================================================================
-- 1. Columns
-- ============================================================================

alter table public."AdvanceOrderLineOverrides" add column if not exists "PosQuantity" numeric(18, 2);
alter table public."AdvanceOrderLineOverrides" add column if not exists "Quantity" numeric(18, 2);
alter table public."AdvanceOrderLineOverrides" add column if not exists "Discount" numeric(18, 2);
alter table public."AdvanceOrderLineOverrides" add column if not exists "GrossAmount" numeric(18, 2);
alter table public."AdvanceOrderLineOverrides" add column if not exists "NetAmount" numeric(18, 2);

alter table public."OrderLineVariantChanges" add column if not exists "Quantity" numeric(18, 2);
alter table public."OrderLineVariantChanges" add column if not exists "NewLineNo" text;

-- ============================================================================
-- 2. Keep overrides (variant and/or quantity) through the POS sync
-- ============================================================================

create or replace function public._advance_order_line_apply_override()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ov public."AdvanceOrderLineOverrides";
begin
  select * into v_ov from public."AdvanceOrderLineOverrides"
  where "TransactionNo" = new."TransactionNo" and "LineNo" = new."LineNo";
  if not found then
    return new;
  end if;

  -- Variant (unchanged rule): POS re-sending its original -> keep the portal's; anything else -> POS wins.
  if coalesce(nullif(trim(new."VariationId"), ''), '') = coalesce(v_ov."PosVariationId", '') then
    new."VariationId" := v_ov."VariationId";
    new."Description" := coalesce(v_ov."Description", new."Description");
  elsif coalesce(nullif(trim(new."VariationId"), ''), '') <> v_ov."VariationId" then
    delete from public."AdvanceOrderLineOverrides"
    where "TransactionNo" = new."TransactionNo" and "LineNo" = new."LineNo";
    return new;
  end if;

  -- Quantity (this file): POS re-sending its original quantity -> keep the split-off quantity / amounts.
  if v_ov."PosQuantity" is not null then
    if new."Quantity" is not distinct from v_ov."PosQuantity" then
      new."Quantity" := v_ov."Quantity";
      new."Discount" := v_ov."Discount";
      new."GrossAmount" := v_ov."GrossAmount";
      new."NetAmount" := v_ov."NetAmount";
    elsif new."Quantity" is distinct from v_ov."Quantity" then
      -- Edited on the POS since - the POS wins (the "-X" line stays; check it by hand).
      update public."AdvanceOrderLineOverrides"
         set "PosQuantity" = null, "Quantity" = null, "Discount" = null, "GrossAmount" = null, "NetAmount" = null
       where "TransactionNo" = new."TransactionNo" and "LineNo" = new."LineNo";
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists "TR_AdvanceOrderLines_VariantOverride" on public."AdvanceOrderLines";
create trigger "TR_AdvanceOrderLines_VariantOverride"
  before insert or update on public."AdvanceOrderLines"
  for each row execute function public._advance_order_line_apply_override();

-- ============================================================================
-- 3. Change Item, whole line or part of its quantity
-- ============================================================================

drop function if exists public.staff_change_advance_order_line_variant(text, text, text, text, text);

create or replace function public.staff_change_advance_order_line_variant(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_line_no text,
  p_variation_id text,
  p_quantity numeric default null       -- how many units change; null / the whole line = the whole line
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
  v_portal_line boolean;
  v_total numeric;
  v_qty numeric;
  v_split boolean;
  v_ratio numeric;
  v_new_line_no text;
  v_n int := 0;
  v_s_disc numeric;
  v_s_gross numeric;
  v_s_net numeric;
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

  v_total := abs(coalesce(v_line."Quantity", 0));
  v_qty := coalesce(p_quantity, v_total);
  if v_qty <= 0 then
    raise exception 'The quantity to change must be more than 0.';
  end if;
  if v_qty > v_total then
    raise exception 'Line % only has % - you can change at most that many.', p_line_no, v_total;
  end if;
  v_split := v_qty < v_total;

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
  -- A portal-made split line ("3-X1"): the POS never sends it, so it's edited directly - no override.
  v_portal_line := p_line_no like '%-X%';

  if v_split then
    -- ---- Part of the line: a new "-X" line for the changed units, the rest stays on this line.
    v_ratio := v_qty / v_total;
    v_s_disc := round(coalesce(v_line."Discount", 0) * v_ratio, 2);
    v_s_gross := round(coalesce(v_line."GrossAmount", 0) * v_ratio, 2);
    v_s_net := round(coalesce(v_line."NetAmount", 0) * v_ratio, 2);

    loop
      v_n := v_n + 1;
      v_new_line_no := regexp_replace(p_line_no, '-X\d+$', '') || '-X' || v_n;
      exit when not exists (select 1 from public."AdvanceOrderLines" where "TransactionNo" = p_no and "LineNo" = v_new_line_no);
    end loop;

    insert into public."AdvanceOrderLines"
      ("TransactionNo", "LineNo", "StoreNo", "POSTerminalNo", "ReceiptNo", "Type", "No", "Description",
       "Quantity", "Price", "Discount", "GrossAmount", "NetAmount", "Date", "Time", "EODID", "UserID",
       "VariationId", "SyncedAtUtc")
    values
      (p_no, v_new_line_no, v_line."StoreNo", v_line."POSTerminalNo", v_line."ReceiptNo", v_line."Type", v_line."No",
       left(v_new_desc, 500),
       sign(coalesce(nullif(v_line."Quantity", 0), 1)) * v_qty, v_line."Price", v_s_disc, v_s_gross, v_s_net,
       v_line."Date", v_line."Time", v_line."EODID", v_line."UserID",
       v_new.variation_id, now());

    if not v_portal_line then
      select * into v_ov from public."AdvanceOrderLineOverrides" where "TransactionNo" = p_no and "LineNo" = p_line_no;
      v_has_ov := found;
      insert into public."AdvanceOrderLineOverrides"
        ("TransactionNo", "LineNo", "PosVariationId", "VariationId", "Description", "ChangedBy", "ChangedAtUtc",
         "PosQuantity", "Quantity", "Discount", "GrossAmount", "NetAmount")
      values
        (p_no, p_line_no, nullif(trim(v_line."VariationId"), ''), coalesce(nullif(trim(v_line."VariationId"), ''), ''),
         v_line."Description", p_admin_username, now(),
         v_line."Quantity",
         v_line."Quantity" - sign(coalesce(nullif(v_line."Quantity", 0), 1)) * v_qty,
         coalesce(v_line."Discount", 0) - v_s_disc,
         coalesce(v_line."GrossAmount", 0) - v_s_gross,
         coalesce(v_line."NetAmount", 0) - v_s_net)
      on conflict ("TransactionNo", "LineNo") do update
        -- keep the POS's ORIGINAL quantity from an earlier split
        set "PosQuantity" = coalesce(public."AdvanceOrderLineOverrides"."PosQuantity", excluded."PosQuantity"),
            "Quantity" = excluded."Quantity", "Discount" = excluded."Discount",
            "GrossAmount" = excluded."GrossAmount", "NetAmount" = excluded."NetAmount",
            "ChangedBy" = excluded."ChangedBy", "ChangedAtUtc" = now();
    end if;

    -- (the BEFORE trigger sees an unchanged variant and the override quantity = new quantity: no-op)
    update public."AdvanceOrderLines"
       set "Quantity" = "Quantity" - sign(coalesce(nullif("Quantity", 0), 1)) * v_qty,
           "Discount" = coalesce("Discount", 0) - v_s_disc,
           "GrossAmount" = coalesce("GrossAmount", 0) - v_s_gross,
           "NetAmount" = coalesce("NetAmount", 0) - v_s_net
     where "TransactionNo" = p_no and "LineNo" = p_line_no;
  else
    -- ---- The whole line (as before).
    if not v_portal_line then
      select * into v_ov from public."AdvanceOrderLineOverrides" where "TransactionNo" = p_no and "LineNo" = p_line_no;
      v_has_ov := found;
      v_pos_variation := case when v_has_ov then v_ov."PosVariationId" else nullif(trim(v_line."VariationId"), '') end;

      if v_pos_variation is not distinct from v_new.variation_id and not (v_has_ov and v_ov."PosQuantity" is not null) then
        delete from public."AdvanceOrderLineOverrides" where "TransactionNo" = p_no and "LineNo" = p_line_no;
      else
        insert into public."AdvanceOrderLineOverrides"
          ("TransactionNo", "LineNo", "PosVariationId", "VariationId", "Description", "ChangedBy", "ChangedAtUtc")
        values (p_no, p_line_no, v_pos_variation, v_new.variation_id, left(v_new_desc, 500), p_admin_username, now())
        on conflict ("TransactionNo", "LineNo") do update
          set "VariationId" = excluded."VariationId", "Description" = excluded."Description",
              "ChangedBy" = excluded."ChangedBy", "ChangedAtUtc" = now();
      end if;
    end if;

    update public."AdvanceOrderLines"
       set "VariationId" = v_new.variation_id, "Description" = left(v_new_desc, 500)
     where "TransactionNo" = p_no and "LineNo" = p_line_no;
  end if;

  insert into public."OrderLineVariantChanges"
    ("OrderKind", "OrderNo", "LineNo", "OldVariationId", "OldDescription", "NewVariationId", "NewDescription", "ChangedBy",
     "Quantity", "NewLineNo")
  values ('Advance', p_no, p_line_no, v_old_variation, v_line."Description", v_new.variation_id,
          case when v_split then v_qty || ' x ' || v_new_desc || ' (new line ' || v_new_line_no || ')' else v_new_desc end,
          p_admin_username, v_qty, v_new_line_no);

  return jsonb_build_object('old_description', v_line."Description", 'new_description', v_new_desc,
                            'quantity', v_qty, 'new_line_no', v_new_line_no);
end;
$$;

grant execute on function public.staff_change_advance_order_line_variant(text, text, text, text, text, numeric) to anon;

notify pgrst, 'reload schema';

-- Result: confirms the new function and the override columns are in place (one row).
select
  (select count(*) from pg_proc where proname = 'staff_change_advance_order_line_variant') as change_item_versions,
  (select count(*) from information_schema.columns
    where table_name = 'AdvanceOrderLineOverrides' and column_name in ('PosQuantity', 'Quantity', 'Discount', 'GrossAmount', 'NetAmount')) as override_qty_columns,
  (select count(*) from information_schema.columns
    where table_name = 'OrderLineVariantChanges' and column_name in ('Quantity', 'NewLineNo')) as log_columns;
