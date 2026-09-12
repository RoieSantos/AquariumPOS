-- Adds a portal-only "Wholesale Applicable" flag to Category Setup, per direct request to mark
-- Aquarium/Stand/Sump as eligible for wholesale pricing. Same pattern as the existing Production
-- Category / Exclude in Transfer Orders / Include in Stock Sync flags (supabase_warehouses_items_tables.sql,
-- supabase_item_warehouse_stock_category_refresh.sql) - a boolean on Categories, surfaced as a
-- checkbox on Category Setup, defaulting to false (opt-in) since only a handful of categories
-- should ever be wholesale-eligible.
--
-- This is foundation only: it records WHICH categories are wholesale-eligible. It does not compute
-- a wholesale price anywhere - Aquarium/Stand/Sump are priced live via GlassPricingSetup/
-- TubularPricingSetup/StickerPricingSetup (supabase_pricing_setup_tables.sql) and
-- computeStandRetailPrice(), not via a flat Items price, so an actual wholesale price/rate is a
-- separate follow-up once it's decided how that price should be derived and when it should apply.

alter table public."Categories" add column if not exists "IsWholesaleApplicable" boolean not null default false;

drop function if exists public.admin_list_categories(text, text);

create or replace function public.admin_list_categories(p_admin_username text, p_admin_password text)
returns table(code text, description text, is_production_category boolean, exclude_in_transfer_orders boolean, include_in_stock_sync boolean, is_wholesale_applicable boolean, item_count bigint)
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
           coalesce(c."ExcludeInTransferOrders", false), coalesce(c."IncludeInStockSync", false),
           coalesce(c."IsWholesaleApplicable", false), count(*)
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where i."CategoryCode" is not null and trim(i."CategoryCode") <> ''
    group by i."CategoryCode", c."Description", c."IsProductionCategory", c."ExcludeInTransferOrders", c."IncludeInStockSync", c."IsWholesaleApplicable"
    order by i."CategoryCode";
end;
$$;

drop function if exists public.admin_update_category_flags(text, text, text, text, boolean, boolean, boolean);

create or replace function public.admin_update_category_flags(
  p_admin_username text,
  p_admin_password text,
  p_code text,
  p_description text,
  p_is_production_category boolean,
  p_exclude_in_transfer_orders boolean,
  p_include_in_stock_sync boolean,
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

  insert into public."Categories" ("Code", "Description", "IsProductionCategory", "ExcludeInTransferOrders", "IncludeInStockSync", "IsWholesaleApplicable")
  values (p_code, nullif(trim(p_description), ''), coalesce(p_is_production_category, false), coalesce(p_exclude_in_transfer_orders, false), coalesce(p_include_in_stock_sync, false), coalesce(p_is_wholesale_applicable, false))
  on conflict ("Code") do update
    set "Description" = excluded."Description",
        "IsProductionCategory" = excluded."IsProductionCategory",
        "ExcludeInTransferOrders" = excluded."ExcludeInTransferOrders",
        "IncludeInStockSync" = excluded."IncludeInStockSync",
        "IsWholesaleApplicable" = excluded."IsWholesaleApplicable";
end;
$$;

grant execute on function public.admin_list_categories(text, text) to anon;
grant execute on function public.admin_update_category_flags(text, text, text, text, boolean, boolean, boolean, boolean) to anon;

-- One-off: mark the three categories already known to need wholesale pricing, so the flag ships
-- pre-checked for them rather than requiring a manual first pass in Category Setup.
update public."Categories" set "IsWholesaleApplicable" = true where "Code" in ('AQUARIUM', 'STAND', 'SUMP');
