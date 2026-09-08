-- Widens staff_search_variants (supabase_warehouses_items_tables.sql) to also return Cost, so
-- picking a Variant on a New Purchase Order line can (re-)validate/fill Unit Cost from the item
-- setup the same way picking the plain Item already does (purchaseOrders.js applyNewPoItemSelection,
-- fed by staff_search_items' own cost column) - this is the BC pattern the user asked for: Unit
-- Cost comes from the item card, per whichever exact item/variant ends up on the line.
--
-- Why this was missing: a Variant can resolve to its OWN "Items" row (Variants."ItemCode",
-- distinct from Variants."MainItemCode") with its own Cost, separate from the parent item's. The
-- New PO row's cost was only ever filled from the PARENT item's cost at Item-pick time; picking a
-- more specific Variant afterwards left that stale even when the variant itself had a different
-- (or, for the parent-only case, no) cost on file. The join staff_search_variants already uses -
-- Items i on i."Code" = coalesce(v."ItemCode", v."MainItemCode") - already resolves "the right
-- item row for this variant, falling back to the parent" correctly; it just never selected Cost.

drop function if exists public.staff_search_variants(text, text, text, text, int, boolean, int);

create or replace function public.staff_search_variants(p_admin_username text, p_admin_password text, p_item_code text default null, p_search text default null, p_limit int default 50, p_use_production_category boolean default null, p_page int default 1)
returns table(variation_id text, main_item_code text, item_code text, sku text, variant_name text, item_name text, quantity_in_stock int, cost numeric, total_count bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_has_item_code boolean := p_item_code is not null and trim(p_item_code) <> '';
  v_has_search boolean := p_search is not null and trim(p_search) <> '';
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if not v_has_item_code and not v_has_search then
    return;
  end if;

  return query
    select v."VariationId"::text, v."MainItemCode"::text, v."ItemCode"::text, v."SKU"::text, v."VariantName"::text,
           i."Name"::text, i."QuantityInStock", i."Cost",
           count(*) over()
    from public."Variants" v
    left join public."Items" i on i."Code" = coalesce(v."ItemCode", v."MainItemCode")
    left join public."Categories" cat on cat."Code" = coalesce(v."CategoryCode", i."CategoryCode")
    where
      (p_use_production_category is null or coalesce(cat."IsProductionCategory", false) = p_use_production_category)
      and not coalesce(cat."ExcludeInTransferOrders", false)
      and case
        when v_has_item_code then
          (v."ItemCode" = p_item_code or v."MainItemCode" = p_item_code)
          and (not v_has_search or v."MainItemCode" ilike '%' || p_search || '%' or v."VariantName" ilike '%' || p_search || '%' or v."SKU" ilike '%' || p_search || '%')
        else
          v."MainItemCode" ilike '%' || p_search || '%' or v."VariantName" ilike '%' || p_search || '%' or v."SKU" ilike '%' || p_search || '%'
      end
    order by v."MainItemCode"
    limit v_limit offset (v_page - 1) * v_limit;
end;
$$;

grant execute on function public.staff_search_variants(text, text, text, text, int, boolean, int) to anon;

notify pgrst, 'reload schema';

-- Verification. Expect exactly one row with cost in the column list.
select
  p.proname,
  pg_get_function_result(p.oid) as returns
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'staff_search_variants';
