-- Fixes the Category column added in supabase_phys_journal_category_column.sql coming back blank
-- for most lines, per direct follow-up (screenshot of the grid with every visible row's Category
-- empty): "can you ensure we flow the category base on the product/ variant category".
--
-- WHY IT WAS BLANK
-- Category (like CategoryCode) is stamped by the Pancake sync onto BOTH Items AND Variants
-- independently (see supabase_pancake_item_sku_match_fix.sql's Variants insert, and
-- supabase_item_warehouse_stock_category_refresh.sql's staff_start_item_warehouse_stock_refresh,
-- which already has to union BOTH for exactly this reason) - one can be populated while the other
-- isn't. The previous version only ever read Items."CategoryCode", and only ever joined Variants
-- when the LINE itself has a VariantId (an item with 2+ variants) - for every other line (the
-- majority: an item with 0 or 1 variant, which the journal treats as "no variant", matching this
-- screenshot's rows), Variants was never even joined, so any category recorded only on that item's
-- own Variants row (not on Items) was invisible.
--
-- THE FIX: resolve category through a fallback chain, preferring the most specific/most recently
-- synced source:
--   1. The Variants row for this line's own Pancake variation (VariantId, or the item's single
--      VariationId when the line has none) - same identity already used for the Pancake-stock
--      lookup.
--   2. Failing that, ANY Variants row under the same Item Code with a non-blank category (picks the
--      most recently synced one) - covers an item whose own VariationId was never captured on
--      Items, but whose underlying Variants row(s) still carry it.
--   3. Failing that, Items."CategoryCode" itself.
-- If all three are blank, the item genuinely has no category recorded anywhere in the portal (not a
-- query problem) - that needs fixing on Item Setup / a re-sync, not here.
--
-- Run AFTER supabase_phys_journal_category_column.sql (the version this redefines).

drop function if exists public._ile_phys_journal_rows(text);

create or replace function public._ile_phys_journal_rows(p_batch_name text)
returns table(
  line_id bigint, item_code text, item_name text, variant_id text, variant_name text,
  warehouse_id text, warehouse_name text,
  qty_calculated numeric, qty_counted numeric, qty_current numeric, quantity numeric,
  updated_at_utc timestamptz, updated_by text,
  product_id text, pancake_variation_id text,
  category_code text, category_name text
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select
    l."LineID", l."ItemCode"::text,
    coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), l."ItemCode")::text,
    l."VariantId"::text, v."VariantName"::text,
    l."WarehouseId"::text, coalesce(w."Name", l."WarehouseId")::text,
    l."QtyCalculated", l."QtyCounted",
    public._ile_balance(l."ItemCode", l."VariantId", l."WarehouseId"),
    case when l."QtyCounted" is null then null
         else l."QtyCounted" - public._ile_balance(l."ItemCode", l."VariantId", l."WarehouseId") end,
    l."UpdatedAtUtc", l."UpdatedBy"::text,
    coalesce(v."ProductId", i."ProductId")::text,
    coalesce(l."VariantId", i."VariationId")::text,
    rc.category_code,
    coalesce(nullif(trim(cat."Description"), ''), rc.category_code)::text
  from public."PhysInventoryJournalLines" l
  left join public."Items" i on i."Code" = l."ItemCode"
  left join public."Variants" v on v."VariationId" = coalesce(l."VariantId", i."VariationId")
  left join public."Warehouses" w on w."ID" = l."WarehouseId"
  left join lateral (
    select coalesce(
      nullif(v."CategoryCode", ''),
      (
        select nullif(vf."CategoryCode", '')
        from public."Variants" vf
        where vf."ItemCode" = l."ItemCode" and nullif(vf."CategoryCode", '') is not null
        order by vf."SyncedAtUtc" desc nulls last
        limit 1
      ),
      nullif(i."CategoryCode", '')
    )::text as category_code
  ) rc on true
  left join public."Categories" cat on cat."Code" = rc.category_code
  where l."BatchName" = p_batch_name
$$;

revoke execute on function public._ile_phys_journal_rows(text) from public, anon, authenticated;

drop function if exists public.admin_get_phys_journal_lines(text, text, text);

create or replace function public.admin_get_phys_journal_lines(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text
)
returns table(
  line_id bigint, item_code text, item_name text, variant_id text, variant_name text,
  warehouse_id text, warehouse_name text,
  qty_calculated numeric, qty_counted numeric, qty_current numeric, quantity numeric,
  updated_at_utc timestamptz, updated_by text,
  product_id text, pancake_variation_id text,
  category_code text, category_name text
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
    select r.* from public._ile_phys_journal_rows(trim(coalesce(p_batch_name, 'DEFAULT'))) r
    order by r.item_name, r.variant_name nulls first, r.warehouse_name;
end;
$$;

grant execute on function public.admin_get_phys_journal_lines(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification. Expect 2 rows.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('_ile_phys_journal_rows', 'admin_get_phys_journal_lines')
order by p.proname;
