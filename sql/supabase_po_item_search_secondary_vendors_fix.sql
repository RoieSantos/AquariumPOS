-- FIX: Purchase Order item picker shows "No items found for this vendor." for items where that
-- vendor is only a SECONDARY vendor (Item Setup > Cost & Vendors > Vendors list, i.e.
-- public."ItemVendors") - e.g. a City Lite item that CityMetal also supplies.
--
-- Cause: supabase_item_cost_and_po_line_cost.sql still contains an OLD staff_search_items that
-- filters on the item's primary Items."VendorCode" only (and has no description column). Re-running
-- that file whole (likely on 2026-10-02, for the posted-date purchase summary) dropped the newer
-- catalog-aware version from supabase_item_vendors_catalog.sql.
--
-- This re-applies ONLY that newer staff_search_items (copied verbatim from
-- supabase_item_vendors_catalog.sql) - primary vendor OR catalog vendor, vendor's own cost
-- prefilled, plus the description column the PO lines use. Nothing else in either file is touched,
-- so no other PO function can be reverted by running this.
--
-- Safe to re-run. Ends with one result: a quick self-test count.

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'staff_search_items'
  loop
    raise notice 'Dropping overload: %', r.signature;
    execute format('drop function %s', r.signature);
  end loop;
end;
$$;

create or replace function public.staff_search_items(p_admin_username text, p_admin_password text, p_search text default null, p_limit int default 20, p_use_production_category boolean default null, p_page int default 1, p_vendor_code text default null)
returns table(code text, name text, category_code text, quantity_in_stock int, total_count bigint, cost numeric, description text)
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
           count(*) over(),
           -- The price agreed with the vendor being ordered from, falling back to the item's own
           -- catalog cost. With no vendor in play (Transfer Orders' picker) the subquery is null
           -- and this is just Items."Cost", exactly as before.
           coalesce(
             (select iv."Cost"
              from public."ItemVendors" iv
              where iv."ItemCode" = i."Code" and iv."VendorCode" = p_vendor_code),
             i."Cost"
           ),
           nullif(trim(i."Description"), '')::text
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where (p_search is null or trim(p_search) = '' or i."Code" ilike '%' || p_search || '%' or i."Name" ilike '%' || p_search || '%')
      and (p_use_production_category is null or coalesce(c."IsProductionCategory", false) = p_use_production_category)
      and not coalesce(c."ExcludeInTransferOrders", false)
      -- Primary tag OR catalog entry - this one clause is what makes a multi-vendor item
      -- orderable from every vendor that carries it.
      and (
        p_vendor_code is null or trim(p_vendor_code) = ''
        or i."VendorCode" = p_vendor_code
        or exists (
          select 1 from public."ItemVendors" iv
          where iv."ItemCode" = i."Code" and iv."VendorCode" = p_vendor_code
        )
      )
    order by i."Name"
    limit v_limit offset (v_page - 1) * v_limit;
end;
$$;

grant execute on function public.staff_search_items(text, text, text, int, boolean, int, text) to anon;

-- Self-test: items orderable from each vendor via the catalog ONLY (not their primary vendor).
-- A non-zero count for a vendor means the picker will now show those items for it.
select v."VendorCode", v."Name" as vendor_name, count(*) as secondary_vendor_items
from public."ItemVendors" iv
join public."Items" i on i."Code" = iv."ItemCode"
join public."Vendors" v on v."VendorCode" = iv."VendorCode"
where i."VendorCode" is distinct from iv."VendorCode"
group by v."VendorCode", v."Name"
order by v."Name";
