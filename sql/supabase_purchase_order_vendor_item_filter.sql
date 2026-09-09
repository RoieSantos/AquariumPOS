-- New Purchase Order's item picker (js/purchaseOrders.js) - per direct request: "can we filter
-- the item base on the selected vendor on the purchase order". Widens staff_search_items with an
-- optional p_vendor_code filter (Items."VendorCode" - see supabase_vendor_tables.sql), same
-- opt-in-when-provided pattern as its existing p_use_production_category filter. New trailing
-- parameter with a default of null, so every other existing caller (Transfer Orders' own item
-- picker in transferOrders.js) is unaffected and keeps searching the full catalog.

drop function if exists public.staff_search_items(text, text, text, int, boolean, int);

create or replace function public.staff_search_items(p_admin_username text, p_admin_password text, p_search text default null, p_limit int default 20, p_use_production_category boolean default null, p_page int default 1, p_vendor_code text default null)
returns table(code text, name text, category_code text, quantity_in_stock int, total_count bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 20), 1), 50);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select i."Code"::text, i."Name"::text, i."CategoryCode"::text, i."QuantityInStock",
           count(*) over()
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where (p_search is null or trim(p_search) = '' or i."Code" ilike '%' || p_search || '%' or i."Name" ilike '%' || p_search || '%')
      and (p_use_production_category is null or coalesce(c."IsProductionCategory", false) = p_use_production_category)
      and not coalesce(c."ExcludeInTransferOrders", false)
      and (p_vendor_code is null or trim(p_vendor_code) = '' or i."VendorCode" = p_vendor_code)
    order by i."Name"
    limit v_limit offset (v_page - 1) * v_limit;
end;
$$;

grant execute on function public.staff_search_items(text, text, text, int, boolean, int, text) to anon;
