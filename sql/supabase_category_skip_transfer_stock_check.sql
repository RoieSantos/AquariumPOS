-- "Skip Stock Check on Transfer" flag on Category Setup, per direct request: "i go for the not check
-- availability check for aquarium / stand / sump only.. we will worry the stock counts later".
--
-- WHY: aquarium / stand / sump units are counted as serials (created by the desktop POS), never
-- posted into the Item Ledger, so the ledger showed 0 / negative at Amaya and Ship was refused
-- ("Cannot ship - not enough stock at Amaya: AQ-019 (0 on hand ..."). Making the ledger match the
-- serials (a one-time adjustment would drift again with every new serial) is deferred.
--
-- What this adds:
--   1. Categories."SkipTransferStockCheck" + the Category Setup read/write RPCs carrying it.
--   2. staff_get_transfer_stock_exempt_lines(doc): which lines of a Transfer Order are in a ticked
--      category - the Manage modal skips its pre-ship check for them and shows Available as "n/a".
--   3. The Transfer_Line ledger trigger posts a ticked line's shipment WITHOUT the "not enough stock
--      at the source warehouse" refusal - the movement is still recorded (the From warehouse's ledger
--      balance for these items goes negative), it just no longer blocks. For an Assemble-to-Order item
--      in a ticked category the component consumption is not blocked either.
--   Receiving, sales and every other category are unchanged. Production Category serial picking at
--   Ship is unchanged too (still one IN_STOCK serial per unit).
--
-- Run AFTER supabase_assemble_to_order.sql (section 3 below is that file's trigger plus the
-- exemption, so running this first would fail on Items."AssembleToOrder" / _ile_line_bom), then
-- deploy docs/js/categorySetup.js, docs/category-setup.html and docs/js/transferOrders.js, then tick
-- the aquarium / stand / sump categories in Category Setup.

alter table public."Categories" add column if not exists "SkipTransferStockCheck" boolean not null default false;

-- ============================================================================
-- 1. Category Setup read/write
-- ============================================================================

drop function if exists public.admin_list_categories(text, text);

create or replace function public.admin_list_categories(p_admin_username text, p_admin_password text)
returns table(
  code text, description text, is_production_category boolean, exclude_in_transfer_orders boolean,
  is_wholesale_applicable boolean, include_in_stock_sync boolean, skip_transfer_stock_check boolean,
  item_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select i."CategoryCode"::text, c."Description"::text, coalesce(c."IsProductionCategory", false),
           coalesce(c."ExcludeInTransferOrders", false),
           coalesce(c."IsWholesaleApplicable", false), coalesce(c."IncludeInStockSync", false),
           coalesce(c."SkipTransferStockCheck", false), count(*)
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where i."CategoryCode" is not null and trim(i."CategoryCode") <> ''
    group by i."CategoryCode", c."Description", c."IsProductionCategory", c."ExcludeInTransferOrders",
             c."IsWholesaleApplicable", c."IncludeInStockSync", c."SkipTransferStockCheck"
    order by i."CategoryCode";
end;
$$;

drop function if exists public.admin_update_category_flags(text, text, text, text, boolean, boolean, boolean, boolean);
drop function if exists public.admin_update_category_flags(text, text, text, text, boolean, boolean, boolean, boolean, boolean);

create or replace function public.admin_update_category_flags(
  p_admin_username text,
  p_admin_password text,
  p_code text,
  p_description text,
  p_is_production_category boolean,
  p_exclude_in_transfer_orders boolean,
  p_is_wholesale_applicable boolean,
  p_include_in_stock_sync boolean,
  p_skip_transfer_stock_check boolean
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  insert into public."Categories" (
    "Code", "Description", "IsProductionCategory", "ExcludeInTransferOrders", "IsWholesaleApplicable",
    "IncludeInStockSync", "SkipTransferStockCheck"
  )
  values (
    p_code, nullif(trim(p_description), ''), coalesce(p_is_production_category, false),
    coalesce(p_exclude_in_transfer_orders, false), coalesce(p_is_wholesale_applicable, false),
    coalesce(p_include_in_stock_sync, false), coalesce(p_skip_transfer_stock_check, false)
  )
  on conflict ("Code") do update
    set "Description" = excluded."Description",
        "IsProductionCategory" = excluded."IsProductionCategory",
        "ExcludeInTransferOrders" = excluded."ExcludeInTransferOrders",
        "IsWholesaleApplicable" = excluded."IsWholesaleApplicable",
        "IncludeInStockSync" = excluded."IncludeInStockSync",
        "SkipTransferStockCheck" = excluded."SkipTransferStockCheck";
end;
$$;

grant execute on function public.admin_list_categories(text, text) to anon;
grant execute on function public.admin_update_category_flags(text, text, text, text, boolean, boolean, boolean, boolean, boolean) to anon;

-- ============================================================================
-- 2. Which Transfer Order lines are exempt
-- ============================================================================

create or replace function public._item_skips_transfer_stock_check(p_item_code text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce((
    select c."SkipTransferStockCheck"
    from public."Items" i
    join public."Categories" c on c."Code" = i."CategoryCode"
    where i."Code" = p_item_code
  ), false);
$$;

revoke execute on function public._item_skips_transfer_stock_check(text) from public, anon, authenticated;

drop function if exists public.staff_get_transfer_stock_exempt_lines(text, text, text);

create or replace function public.staff_get_transfer_stock_exempt_lines(
  p_admin_username text,
  p_admin_password text,
  p_document_no text
)
returns table(line_no bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select tl."Line No."::bigint
    from public."Transfer_Line" tl
    where tl."Document No." = p_document_no
      and public._item_skips_transfer_stock_check(tl."Item No.");
end;
$$;

grant execute on function public.staff_get_transfer_stock_exempt_lines(text, text, text) to anon;

-- ============================================================================
-- 3. Ledger trigger: exempt lines ship without the negative-stock refusal
-- ============================================================================
-- Same as supabase_assemble_to_order.sql's version; only v_block (p_prevent_negative) is new.

create or replace function public._ile_transfer_line_post()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ship_delta numeric;
  v_recv_delta numeric;
  v_header record;
  v_actor text := coalesce(nullif(trim(coalesce(new."Last Actor", '')), ''), 'system');
  v_variant text := nullif(trim(coalesce(new."Variant ID", '')), '');
  v_key record;
  v_comp record;
  v_have numeric;
  v_build numeric;
  v_tx bigint;
  v_has_components boolean;
  v_block boolean;
begin
  if not coalesce((select s."TransferPostingEnabled" from public."ItemLedgerSetup" s limit 1), true) then
    return new;
  end if;

  v_ship_delta := coalesce(new."Qty Shipped", 0) - case when tg_op = 'UPDATE' then coalesce(old."Qty Shipped", 0) else 0 end;
  v_recv_delta := coalesce(new."Qty Received", 0) - case when tg_op = 'UPDATE' then coalesce(old."Qty Received", 0) else 0 end;

  if coalesce(new."Qty Shipped", 0) <= 0 then
    v_recv_delta := 0;
  end if;

  if v_ship_delta = 0 and v_recv_delta = 0 then
    return new;
  end if;

  select "From Warehouse ID" as from_id, "From Warehouse" as from_name,
         "To Warehouse ID" as to_id, "To Warehouse" as to_name
    into v_header
    from public."Transfer_Header" where "No." = new."Document No.";

  if v_ship_delta <> 0 then
    -- Category Setup > Skip Stock Check on Transfer: post the movement, but never refuse it.
    v_block := not public._item_skips_transfer_stock_check(new."Item No.");

    -- Assemble-to-Order: build the shortfall at the From warehouse before it ships.
    if v_ship_delta > 0 and exists (select 1 from public."Items" i where i."Code" = new."Item No." and i."AssembleToOrder") then
      select k.item_code, k.variant_id into v_key from public._ile_resolve_stock_key(new."Item No.", v_variant) k;
      v_have := greatest(0, public._ile_balance(v_key.item_code, v_key.variant_id, coalesce(v_header.from_id, '')));
      v_build := greatest(0, v_ship_delta - v_have);

      if v_build > 0 then
        v_has_components := false;
        v_tx := nextval('public.ile_transaction_no_seq');

        for v_comp in
          select b.component_code as code, b.qty_per as qty_per from public._ile_line_bom(new."Document No.", new."Line No."::bigint, new."Item No.") b
        loop
          v_has_components := true;
          perform public._ile_post(
            'Negative Adjmt.', v_comp.code, null, coalesce(v_header.from_id, ''), -(v_build * v_comp.qty_per),
            public._ile_today(), 'Assembly', new."Document No.",
            'Assembled ' || v_build || ' x ' || new."Item No." || ' for ' || new."Document No.", v_tx, v_actor,
            null, v_block
          );
        end loop;

        if not v_has_components then
          raise exception 'Cannot ship % - it is an Assemble-to-Order item but has no BOM components in Item Setup.', new."Item No.";
        end if;

        perform public._ile_post(
          'Positive Adjmt.', new."Item No.", v_variant, coalesce(v_header.from_id, ''), v_build,
          public._ile_today(), 'Assembly', new."Document No.",
          'Assembled for ' || new."Document No.", v_tx, v_actor
        );
      end if;
    end if;

    perform public._ile_post(
      'Transfer', new."Item No.", v_variant, coalesce(v_header.from_id, ''), -v_ship_delta,
      public._ile_today(), 'Transfer Shipment', new."Document No.",
      'Shipped to ' || coalesce(v_header.to_name, v_header.to_id, '?'), null, v_actor,
      null, v_block
    );
  end if;

  if v_recv_delta <> 0 then
    perform public._ile_post(
      'Transfer', new."Item No.", v_variant, coalesce(v_header.to_id, ''), v_recv_delta,
      public._ile_today(), 'Transfer Receipt', new."Document No.",
      'Received from ' || coalesce(v_header.from_name, v_header.from_id, '?'), null, v_actor
    );
  end if;

  return new;
end;
$$;

notify pgrst, 'reload schema';

-- Verification. Expect the column, and 3 functions with has_anon_execute = true.
select column_name, data_type, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'Categories' and column_name = 'SkipTransferStockCheck';

select p.proname, pg_get_function_identity_arguments(p.oid) as arguments,
       has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('admin_list_categories', 'admin_update_category_flags', 'staff_get_transfer_stock_exempt_lines')
order by p.proname;
