-- Retires the "Include in Stock Sync" category flag, per "no need to rely on the setup 'Include in
-- stock sync' under categories ... i want everything to be monitored as of the moment".
--
-- That flag only ever existed to limit which categories the Stock On Hand page's "Refresh from
-- Pancake" button pulled (supabase_item_warehouse_stock_category_refresh.sql). Stock is now owned by
-- the portal's Item Ledger, which tracks EVERY item, so there is nothing left for it to control:
--   * Category Setup no longer shows or saves it (admin_list_categories / admin_update_category_flags
--     below drop the column and the parameter - docs/js/categorySetup.js is updated to match).
--   * Stock On Hand and its Category filter already ignore it (see supabase_item_ledger_hooks.sql).
--   * The one remaining Pancake stock pull - the optional opening-balance seed - now covers every
--     product instead of only flagged categories.
--
-- The Categories."IncludeInStockSync" column itself is left in place, unused: dropping it would
-- break any older function that still names it, for no benefit. Nothing reads or writes it now.
--
-- Run BEFORE deploying the matching docs/js/categorySetup.js (it stops sending the old parameter).

-- ============================================================================
-- 1. Category Setup RPCs without the flag
-- ============================================================================

drop function if exists public.admin_list_categories(text, text);

create or replace function public.admin_list_categories(p_admin_username text, p_admin_password text)
returns table(code text, description text, is_production_category boolean, exclude_in_transfer_orders boolean, is_wholesale_applicable boolean, item_count bigint)
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
           coalesce(c."IsWholesaleApplicable", false), count(*)
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where i."CategoryCode" is not null and trim(i."CategoryCode") <> ''
    group by i."CategoryCode", c."Description", c."IsProductionCategory", c."ExcludeInTransferOrders", c."IsWholesaleApplicable"
    order by i."CategoryCode";
end;
$$;

drop function if exists public.admin_update_category_flags(text, text, text, text, boolean, boolean, boolean, boolean);
drop function if exists public.admin_update_category_flags(text, text, text, text, boolean, boolean, boolean);

create or replace function public.admin_update_category_flags(
  p_admin_username text,
  p_admin_password text,
  p_code text,
  p_description text,
  p_is_production_category boolean,
  p_exclude_in_transfer_orders boolean,
  p_is_wholesale_applicable boolean
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

  insert into public."Categories" ("Code", "Description", "IsProductionCategory", "ExcludeInTransferOrders", "IsWholesaleApplicable")
  values (p_code, nullif(trim(p_description), ''), coalesce(p_is_production_category, false), coalesce(p_exclude_in_transfer_orders, false), coalesce(p_is_wholesale_applicable, false))
  on conflict ("Code") do update
    set "Description" = excluded."Description",
        "IsProductionCategory" = excluded."IsProductionCategory",
        "ExcludeInTransferOrders" = excluded."ExcludeInTransferOrders",
        "IsWholesaleApplicable" = excluded."IsWholesaleApplicable";
end;
$$;

grant execute on function public.admin_list_categories(text, text) to anon;
grant execute on function public.admin_update_category_flags(text, text, text, text, boolean, boolean, boolean) to anon;

-- ============================================================================
-- 2. The optional Pancake snapshot pull now covers every product
-- ============================================================================

-- Only used by the OPTIONAL one-time opening-balance seed
-- (supabase_item_ledger_seed_opening_balances.sql), which reads the ItemWarehouseStockCache this
-- fills. Returns every distinct Pancake product id the caller should then walk; no category filter.
drop function if exists public.staff_start_item_warehouse_stock_refresh(text, text);

create or replace function public.staff_start_item_warehouse_stock_refresh(
  p_admin_username text,
  p_admin_password text
)
returns table(product_id text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  truncate public."ItemWarehouseStockCache";

  return query
    select distinct p.product_id::text from (
      select "ProductId" as product_id from public."Items" where "ProductId" is not null and trim("ProductId") <> ''
      union
      select "ProductId" as product_id from public."Variants" where "ProductId" is not null and trim("ProductId") <> ''
    ) p
    order by 1;
end;
$$;

grant execute on function public.staff_start_item_warehouse_stock_refresh(text, text) to anon;

notify pgrst, 'reload schema';
