-- Physical Inventory Journal - adds an "Only categories flagged Include in Stock Sync" filter to
-- Calculate Inventory, per direct request: "if the physical inventory journal > Calculate Inventory
-- can you include in the filter the 'Include stock count' - if the category is yes then only that
-- category will flow in the Physical Inventory Journal".
--
-- Run AFTER supabase_item_ledger_phys_inventory_journal.sql and
-- supabase_category_restore_stock_sync_flag.sql (the flag this reads).
--
-- OPT-IN, like the existing Category/Item filters: unchecked (the default) calculates every active
-- item, same as before. Checked, it only pulls in items whose category has
-- Categories."IncludeInStockSync" = true - lets a count run be narrowed to just the categories
-- flagged for it, without picking them one at a time in the single Category dropdown. Combines with
-- that dropdown and the item filter (all three AND together) rather than replacing them.

drop function if exists public.admin_calculate_phys_inventory(text, text, text, text, text, text);

create or replace function public.admin_calculate_phys_inventory(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text,
  p_warehouse_id text,
  p_category_code text default null,
  p_search text default null,
  p_only_stock_sync_categories boolean default false
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch text := trim(coalesce(p_batch_name, 'DEFAULT'));
  v_warehouse text := trim(coalesce(p_warehouse_id, ''));
  v_count int;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_batch = '' then
    raise exception 'A batch name is required.';
  end if;

  if v_warehouse = '' or not exists (select 1 from public."Warehouses" where "ID" = v_warehouse) then
    raise exception 'Pick a location to calculate inventory for.';
  end if;

  with variant_counts as (
    select v."ItemCode" as item_code, count(*) as cnt from public."Variants" v group by v."ItemCode"
  ),
  keys as (
    -- An item with 2+ variants: one key per variant.
    select i."Code" as item_code, v."VariationId" as variant_id
    from public."Items" i
    join public."Variants" v on v."ItemCode" = i."Code"
    join variant_counts vc on vc.item_code = i."Code" and vc.cnt >= 2
    where coalesce(i."IsActive", true)
    union all
    -- Everything else (no variants, or exactly one - which is really just the item itself): one
    -- key, no variant. Mirrors _ile_resolve_stock_key's own threshold exactly.
    select i."Code", null
    from public."Items" i
    left join variant_counts vc on vc.item_code = i."Code"
    where coalesce(i."IsActive", true) and coalesce(vc.cnt, 0) < 2
  ),
  filtered as (
    select k.item_code, k.variant_id
    from keys k
    join public."Items" i on i."Code" = k.item_code
    left join public."Variants" v on v."VariationId" = k.variant_id
    left join public."Categories" cat on cat."Code" = i."CategoryCode"
    where (p_category_code is null or trim(p_category_code) = '' or i."CategoryCode" = p_category_code)
      and (not coalesce(p_only_stock_sync_categories, false) or coalesce(cat."IncludeInStockSync", false) is true)
      and (
        p_search is null or trim(p_search) = ''
        or k.item_code ilike '%' || trim(p_search) || '%'
        or i."Name" ilike '%' || trim(p_search) || '%'
        or v."VariantName" ilike '%' || trim(p_search) || '%'
      )
  )
  insert into public."PhysInventoryJournalLines"
    ("BatchName", "ItemCode", "VariantId", "WarehouseId", "QtyCalculated", "UpdatedAtUtc", "UpdatedBy")
  select v_batch, f.item_code, f.variant_id, v_warehouse,
         public._ile_balance(f.item_code, f.variant_id, v_warehouse), now(), p_admin_username
  from filtered f
  on conflict ("BatchName", "ItemCode", (coalesce("VariantId", '')), "WarehouseId")
  do update set
    "QtyCalculated" = case when public."PhysInventoryJournalLines"."QtyCounted" is null
                            then excluded."QtyCalculated"
                            else public."PhysInventoryJournalLines"."QtyCalculated" end,
    "UpdatedAtUtc" = now(),
    "UpdatedBy" = excluded."UpdatedBy";

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.admin_calculate_phys_inventory(text, text, text, text, text, text, boolean) to anon;

notify pgrst, 'reload schema';
